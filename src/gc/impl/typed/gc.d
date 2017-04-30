/**
 * Contains a garbage collection implementation that organizes memory based on
 * the type information.
 *
 */

module gc.impl.typed.gc;

import core.bitop; //bsf
import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import corelib = core.sync.mutex;
import core.thread;

import gc.config;
import gc.gcinterface;
import os = gc.os; //os_mem_map, os_mem_unmap

import rt.util.container.array;


import core.internal.spinlock;

//static import core.memory;

///Identifier for the size of a page in bytes
enum PAGE_SIZE = 4096; //4kb

extern (C)
{
    // to allow compilation of this module without access to the rt package,
    // make these functions available from rt.lifetime

    /// Call the destructor/finalizer on a given object.
    void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;
    /// Check if the object at this memroy has a destructor/finalizer.
    int rt_hasFinalizerInSegment(void* p, size_t size, uint attr, in void[] segment) nothrow;

    // Declared as an extern instead of importing core.exception
    // to avoid inlining - see issue 13725.

    /// Raise an error that describes an invalid memory operation.
    void onInvalidMemoryOperationError() @nogc nothrow;
    /// Raise an error that describes the system as being out of memory.
    void onOutOfMemoryErrorNoGC() @nogc nothrow;
}



uint mem_maps, mem_unmaps;

uint mem_mappedSize, mem_unmappedSize;


void* os_mem_map(size_t nbytes) nothrow
{
    debug
    {
        mem_maps++;
        mem_mappedSize+= nbytes;
    }

    return os.os_mem_map(nbytes);
}

int os_mem_unmap(void* base, size_t nbytes) nothrow
{
    debug
    {
        mem_unmaps++;
        mem_unmappedSize+=nbytes;
    }
    return os.os_mem_unmap(base, nbytes);
}




/**
 * The Typed GC organizes memory based on type.
 */
class TypedGC : GC
{

    /// Array of roots to search for pointers.
    Array!Root roots;
    /// Array of ranges of data to search for pointers.
    Array!Range ranges;

    /**
    * The boundaries of the heap.
    *
    * Used to detect if a pointer is contained in the GC managed heap.
    */
    void* heapBottom, heapTop;

    ///The memory used by the system.
    //initialized to 64kb/1Mb (256 pages) and assumed to not grow
    MemoryChunk systemMemory;

    /// The list of all memory chunks used by the heap.
    MemoryChunk* heapMemory;
    /// The chunk currently used to perform allocations.
    MemoryChunk* currentChunk;

    /// Mutexes used by the system and heap allocators respectively.
    //Mutex smutex, hmutex;
    auto smutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);
    auto hmutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);


    uint hashSize = 101;
    TypeManager[] hashArray;
    UntypedManager untypedManager;

    //perform a simple double hash. Should be enough, but can be optimized later
    size_t hashFunc(size_t hash, uint i) nothrow
    {
        return ((hash%hashSize) + i*(hash % 7))%hashSize;
    }

    /**
     * Search by type to find the manager for this type
     */
    TypeManager* getTypeManager(size_t size, const TypeInfo ti) nothrow
    {
        uint attempts = 0;

        size_t hash = ti.toHash();

        while(true)
        {
            auto pos = hashFunc(hash, attempts);

            if(hashArray[pos].info is null)
            {
                hashArray[pos].__ctor(size, ti);

                return &(hashArray[pos]);
            }
            else if(hashArray[pos].info is ti)
            {
                return &(hashArray[pos]);
            }

            attempts++;
        }
    }

    /**
     * SearchNode describes a node in a binary tree.
     *
     * This node is used when searching for a bucket by pointer.
     */
    struct SearchNode
    {
        TypeBucket* bucket;
        SearchNode* left;
        SearchNode* right;

        int height;
    }

    /// This is the root node in a binary tree
    SearchNode* root;

    //set the ranges of the heap
    void* memoryBottom = cast(void*)size_t.max, memoryTop = cast(void*)0;

    ///insert a SearchNode into the binary tree
    void searchNodeInsert(SearchNode* node) nothrow
    {
        if(root is null)
        {
            root = node;
            return;
        }

        searchNodeInsertHelper(root, node);

        if(node.bucket.memory < memoryBottom)
            memoryBottom = node.bucket.memory;

        if(node.bucket.memory > memoryTop) //buckets don't overlap, so this is fine
            memoryTop = node.bucket.memory + node.bucket.objectSize * node.bucket.numberOfObjects;



        return;
    }


    void searchNodeInsertHelper(ref SearchNode* current, SearchNode* node) nothrow
    {
        if( node.bucket.memory < current.bucket.memory)
        {
            if(current.left is null)
            {
                current.left = node;
                current.left.height = 1;
            }
            else
            {
                searchNodeInsertHelper(current.left, node);
            }
        }
        else //we will never have duplicates
        {
            if(current.right is null)
            {
                current.right = node;
                current.right.height = 1;
            }
            else
            {
                searchNodeInsertHelper(current.right, node);
            }
        }


        int leftHeight = getHeight(current.left);
        int rightHeight = getHeight(current.right);

        current.height = ((leftHeight>rightHeight)?leftHeight:rightHeight) + 1;

        int balance = leftHeight - rightHeight;

        if(balance > 1)
        {
            if(node.bucket.memory < current.left.bucket.memory)
            {
                //left left rotation
                current = LLRot(current);
                return;
            }

            //left right rotation
            current.left  = RRRot(current.left);
            current = LLRot(current);
        }
        else if(balance < -1)
        {
            if(node.bucket.memory < current.right.bucket.memory)
            {
                //right left rotation
                current.right = LLRot(current.left);
                current = RRRot(current);
                return;
            }
            //right right rotation
            current = RRRot(current);
            int breaker = 0;
        }

    }

    SearchNode* LLRot(SearchNode* k2) nothrow
    {
        SearchNode* k1 = k2.left;
        SearchNode* y = k1.right;

        k2.left = y;
        k1.right = k2;

        //height updates
        k2.height = max(getHeight(k2.left), getHeight(k2.left)) + 1;
        k1.height = max(getHeight(k1.left), getHeight(k1.left)) + 1;

        int breaker = 0;

        return k1;
    }

    SearchNode* RRRot(SearchNode* k2) nothrow
    {
        SearchNode* k1 = k2.right;
        SearchNode* y = k1.left;

        k2.right = y;
        k1.left = k2;


        //height updates
        k2.height = max(getHeight(k2.left), getHeight(k2.left)) + 1;
        k1.height = max(getHeight(k1.left), getHeight(k1.left)) + 1;

        int breaker = 0;

        return k1;
    }

    int max(int a, int b) nothrow
    {
        return (a>b)?a:b;
    }

    int getHeight(SearchNode* node) nothrow
    {
        if(node is null)
            return 0;

        return node.height;
    }

    ///Search the Binary tree for the bucket containing ptr
    TypeBucket* findBucket(void* ptr) nothrow
    {
        //check if the pointer is in the boundaries of the heap memory
        if(ptr < heapBottom || ptr >= heapTop)
            return null;

        SearchNode* current = root;
        while(current !is null)
        {
            debug
            {
                auto currentBot = current.bucket.memory;
                auto currentTop = current.bucket.memory + current.bucket.objectSize * current.bucket.numberOfObjects;
            }

            if(current.bucket.containsObject(ptr))
                return current.bucket;

            current = (ptr < current.bucket.memory)? current.left:current.right;
        }

        return null;
    }



    //recursive function for finalizing all buckets in the binary tree
    void finalizeBuckets(SearchNode* node)
    {
        if(node is null)
            return;

        if(node.left !is null)
            finalizeBuckets(node.left);
        if(node.right !is null)
            finalizeBuckets(node.right);

        node.bucket.dtor();
    }



    /**
     * Initialize the GC based on command line configuration.
     *
     * Params:
     *  gc = The reference to the GC instance the language will use.
     *
     * Throws:
     *  OutOfMemoryError if failed to initialize GC due to not enough memory.
     */
    static void initialize(ref GC gc)
    {
        import core.stdc.string : memcpy;

        if (config.gc != "typed")
            return;

        auto p = cstdlib.malloc(__traits(classInstanceSize, TypedGC));
        if (!p)
            onOutOfMemoryErrorNoGC();

        auto init = typeid(TypedGC).initializer();
        assert(init.length == __traits(classInstanceSize, TypedGC));
        auto instance = cast(TypedGC) memcpy(p, init.ptr, init.length);
        instance.__ctor();

        gc = instance;
    }

    /**
     * Finalize the GC.
     *
     * This calls the destructor for the GC instance, and then free's the
     * instance itself.
     *
     * Params:
     *  gc = The reference to the GC instance the language used.
     */
    static void finalize(ref GC gc)
    {
        if (config.gc != "typed")
            return;

        auto instance = cast(TypedGC) gc;
        destroy(instance);
        cstdlib.free(cast(void*) instance);

        debug
        {
            import core.stdc.stdio;
            printf("There were %d mem_maps and %d mem_unmaps\n",
                    mem_maps, mem_unmaps);

            printf("Heap use at exit: %d\n\n", mem_mappedSize-mem_unmappedSize);

            printf("press enter to continue...\n");
            getchar();
        }
    }

    /**
     * MemoryChunk describes a chunk of memory obtained directly from the OS.
     */
    struct MemoryChunk
    {
        /// The start of the memory this chunk describes.
        void* start;
        /// The size of the MemoryChunk.
        size_t chunkSize;
        /// Where in the chunk to pop memory from when allocating.
        void* offset;
        /// A reference to the next chunk.
        //(used to avoid an additional structure for making a linked list)
        MemoryChunk* nextChunk;

        /**
         * MemoryChunk constructor.
         *
         * Initializes this chunk with new memory from the OS
         */
        this(size_t size) nothrow
        {
            chunkSize = size;
            start = os_mem_map(chunkSize);
            if (start is null)
                onOutOfMemoryErrorNoGC;
            offset = start;
            nextChunk = null;
        }
        ~this()
        {
            os_mem_unmap(start, chunkSize);
        }
    }

    /**
     * System Alloc.
     *
     * This is used to allocate for internal structures. It is assumed to never fail
     * for 2 reasons:
     *  1. There is plenty of memory for the system to use internally. We should
     *     always have enough.
     *  2. The memory usage for a program should eventually hit a peak. Given enough
     *     time, there will be plenty of storage space after a collection to not
     *     warrant creating more internal objects.
     *
     * The System Alloc is designed to be thread safe.
     */
    void* salloc(size_t size) nothrow
    {
        smutex.lock();
        scope (exit)
            smutex.unlock();

        void* oldOffset = systemMemory.offset;
        systemMemory.offset += size;
        debug
        {
            //shouldn't happen, but still check for it in debug during testing
            if (systemMemory.offset > systemMemory.start + systemMemory.chunkSize)
                onInvalidMemoryOperationError();
        }

        return oldOffset;
    }

    /**
     * Heap Alloc.
     *
     * This is used to get GC managed memory for new buckets to use. This allocator
     * is lazy in the sense that if it doesn't have enough room in one memory chunk
     * to fulfill an allocation, it makes a new one.
     *
     * This can/should be optimized later to avoid fragmentation.
     *
     * This allocation could possibly fail, and will throw an OutOfMemoryError if it
     * does.
     */
    void* halloc(size_t size) nothrow
    {
        hmutex.lock();
        scope (exit)
            hmutex.unlock();

        //check size of allocation? Do something special if allocating a lot?
        //(a big object, a big array, a large amount of memory is reserved?)

        if (currentChunk.offset + size > currentChunk.start + currentChunk.chunkSize)
        {
            //or something generated by a growth algorithm?
            size_t newChunkSize = 2 * PAGE_SIZE;
            MemoryChunk* newChunk = cast(MemoryChunk*) salloc(MemoryChunk.sizeof);

            //may throw out of memory error
            newChunk.__ctor(newChunkSize);

            currentChunk.nextChunk = newChunk;
            currentChunk = newChunk;

            //adjust the heap boundaries
            if (currentChunk.start < heapBottom)
                heapBottom = currentChunk.start;

            if (heapTop < currentChunk.start + currentChunk.chunkSize)
                heapTop = currentChunk.start + currentChunk.chunkSize;

        }

        void* oldOffset = currentChunk.offset;
        currentChunk.offset += size;
        return oldOffset;
    }

    /**
     * Constructor for the Typed GC.
     */
    this()
    {
        import core.stdc.string: memset;

        //is this enough?
        //should system memory actually grow?
        systemMemory = MemoryChunk(10 * PAGE_SIZE);
        heapMemory = cast(MemoryChunk*) salloc(MemoryChunk.sizeof);
        heapMemory.__ctor(2 * PAGE_SIZE); //is this enough to start?
        currentChunk = heapMemory;

        heapBottom = currentChunk.start;
        heapTop = currentChunk.start + currentChunk.chunkSize;

        TypeBucket._gc = this;
        TypeManager._gc = this;
        UntypedManager._gc = this;

        //calculate how much memory for hash
        uint numberOfPages = 1;
        while(hashSize*TypeManager.sizeof > numberOfPages*PAGE_SIZE)
            numberOfPages++;

        //keep this to free memory later
        size_t hashMemorySize = numberOfPages*PAGE_SIZE;
        void* memory = os_mem_map(hashMemorySize);

        //pretend the memory is actually an array
        hashArray = (cast(TypeManager*)memory)[0 .. hashSize];
        memset(memory, 0, hashSize*TypeManager.sizeof);

        //start the stack with tons of memory so it doesn't overflow
        scanStack = ScanStack(3*PAGE_SIZE);
    }

    ~this()
    {
        finalizeBuckets(root);

        while(heapMemory !is null)
        {
            os_mem_unmap(heapMemory.start, heapMemory.chunkSize);
            heapMemory = heapMemory.nextChunk;
        }


        //calculate how much memory for hash
        uint numberOfPages = 1;
        while(hashSize*TypeManager.sizeof > numberOfPages*PAGE_SIZE)
            numberOfPages++;

        //keep this to free memory later
        size_t hashMemorySize = numberOfPages*PAGE_SIZE;

        os_mem_unmap(hashArray.ptr, hashMemorySize);

        roots.reset();
        ranges.reset();
    }

    /**
     * Destructor for the Typed GC.
     */
    void Dtor() //can I remove this?
    {

    }

    /**
     * Enables the GC if disable() was previously called. Must be called
     * for each time disable was called in order to enable the GC again.
     */
    void enable()
    {
        //need some kind of mechanism for enabling and disabling.
    }

    /**
     * Disable the GC. The GC may still run if it deems necessary.
     */
    void disable()
    {
        //need some kind of mechanism for enabling and disabling.
    }

    /**
     * Begins a full collection, scanning all stack segments for roots.
     *
     * Returns:
     *  The number of pages freed.
     */
    void collect() nothrow
    {
        //lock things
        //disable threads
        thread_suspendAll();

        //prepare for scanning
        //prepare();

        //scan and mark
        thread_scanAll(&mark);

        foreach (root; roots)
        {
            mark(cast(void*)&root.proot, cast(void*)(&root.proot + 1));
        }

        foreach (range; ranges)
        {

            mark(range.pbot, range.ptop);
        }

        //resume threads
        thread_processGCMarks(&isMarked);
        thread_resumeAll();

        //sweep maybe? (alternatively do a lazy sweep)

    }

    /**
     * Begins a full collection while ignoring all stack segments for roots.
     */
    void collectNoStack() nothrow
    {
    }

    /**
     * Minimize free space usage.
     */
    void minimize() nothrow
    {
        //do nothing for now
        //what can we do, honestly?
        //think about it
    }

    /**
     * Returns a bit field representing all block attributes set for the memory
     * referenced by p.
     *
     * Params:
     *  p = A pointer to the base of a valid memory block or to null.
     *
     * Returns:
     *  A bit field containing any bits set for the memory block referenced by
     *  p or zero on error.
     */
    uint getAttr(void* p) nothrow
    {

        //p should be pointing to the base of an objects

        //do a check somewhere

        return 0;
    }

    /**
     * Sets the specified bits for the memory references by p.
     *
     * If p was not allocated by the GC, points inside a block, or is null, no
     * action will be taken.
     *
     * Params:
     *  p = A pointer to the base of a valid memory block or to null.
     *  mask = A bit field containing any bits to set for this memory block.
     *
     * Returns:
     *  The result of a call to getAttr after the specified bits have been
     *  set.
     */
    uint setAttr(void* p, uint mask) nothrow
    {
        //p must point to the base of an object
        return 0;
    }

    /**
     * Clears the specified bits for the memory references by p.
     *
     * If p was not allocated by the GC, points inside a block, or is null, no
     * action will be taken.
     *
     * Params:
     *  p = A pointer to the base of a valid memory block or to null.
     *  mask = A bit field containing any bits to clear for this memory block.
     *
     * Returns:
     *  The result of a call to getAttr after the specified bits have been
     *  cleared
     */
    uint clrAttr(void* p, uint mask) nothrow
    {
        return 0;
    }

    /**
     * Requests an aligned block of managed memory from the garbage collector.
     *
     * Params:
     *  size = The desired allocation size in bytes.
     *  bits = A bitmask of the attributes to set on this block.
     *  ti = TypeInfo to describe the memory.
     *
     * Returns:
     *  A reference to the allocated memory or null if no memory was requested.
     *
     * Throws:
     *  OutOfMemoryError on allocation failure
     */
    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        if(ti is null)
        {
            return untypedManager.alloc(size, bits);
        }

        TypeManager* type = getTypeManager(size, ti);

        return type.alloc(bits);
    }

    /**
     * Requests an aligned block of managed memory from the garbage collector.
     *
     * Params:
     *  size = The desired allocation size in bytes.
     *  bits = A bitmask of the attributes to set on this block.
     *  ti = TypeInfo to describe the memory.
     *
     * Returns:
     *  Information about the block of memory in the form of a BlkInfo object.
     *
     * Throws:
     *  OutOfMemoryError on allocation failure
     */
    BlkInfo qalloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        BlkInfo retval;

        if(ti is null)
        {
            auto type = untypedManager.alloc(size, bits);
        }

        TypeManager* type = getTypeManager(size, ti);


        return type.qalloc(bits);

        //auto sizey = type.allocateNode.bucket.objectSize;
        //retval.size = sizey;


        //retval.base = type.alloc(bits);

        //retval.attr = bits;
        //return retval;
    }

    /**
     * Requests an aligned block of managed memory from the garbage collector,
     * which is initialized with all bits set to zero.
     *
     * Params:
     *  size = The desired allocation size in bytes.
     *  bits = A bitmask of the attributes to set on this block.
     *  ti = TypeInfo to describe the memory.
     *
     * Returns:
     *  A reference to the allocated memory or null if no memory was requested.
     *
     * Throws:
     *  OutOfMemoryError on allocation failure.
     */
    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        import core.stdc.string : memset;

        void* p = malloc(size, bits, ti);

        if (size && p)
            return memset(p, 0, size);

        return null;
    }

    /**
     * Request that the GC reallocate a block of memory, attempting to adjust
     * the size in place if possible. If size is 0, the memory will be freed.
     *
     * If p was not allocated by the GC, points inside a block, or is null, no
     * action will be taken.
     *
     * Params:
     *  p = A pointer to the root of a valid memory block or to null.
     *  size = The desired allocation size in bytes.
     *  bits = A bitmask of the attributes to set on this block.
     *  ti = TypeInfo to describe the memory.
     *
     * Returns:
     *  A reference to the allocated memory on success or null if size is
     *  zero.
     *
     * Throws:
     *  OutOfMemoryError on allocation failure.
     */
    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {

        //TypeBucket* typeBucket = buckets.retrieve(size, ti);
        //
        //p = cstdlib.realloc(p, size);
        //
        //if (size && p is null)
        //onOutOfMemoryErrorNoGC();
        //return p;

        return null;
    }

    /**
     * Attempt to in-place enlarge the memory block pointed to by p by at least
     * minsize bytes, up to a maximum of maxsize additional bytes.
     * This does not attempt to move the memory block (like realloc() does).
     *
     * Params:
     *  p = The location of the memory to extend.
     *  minsize = The minimum size the system will try to extend to.
     *  maxsize = The maximum size the system will try to extend to.
     *  ti = TypeInfo to describe the memory.
     *
     * Returns:
     *  0 if could not extend p,
     *  total size of entire memory block if successful.
     */
    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {

        //find p, check if extendable?

        //if so, extend?

        //only types that are allowed to be extendable:
        //arrays
        //ray data

        return 0;
    }

    /**
     * Requests that at least size bytes of memory be obtained from the operating
     * system and marked as free.
     *
     * Params:
     *  size = The desired size in bytes.
     *
     * Returns:
     *  The actual number of bytes reserved or zero on error.
     */
    size_t reserve(size_t size) nothrow
    {
        //create some raw memory for type buckets to use

        return 0;
    }

    /**
     * Deallocates the memory referenced by p.
     *
     * If p was not allocated by the GC, points inside a block, is null, or
     * if free is called from a finalizer, no action will be taken.
     *
     * Params:
     *  p = A pointer to the root of a valid memory block or to null.
     */
    void free(void* p) nothrow
    {
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     *
     * Params:
     *  p = A pointer to the root or the interior of a valid memory block or to
     *      null.
     *
     * Returns:
     *  The base address of the memory block referenced by p or null on error.
     */
    void* addrOf(void* p) nothrow
    {
        return null;
    }

    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     *
     * Params:
     *  p = A pointer to the root of a valid memory block or to null.
     *
     * Returns:
     *  The size in bytes of the memory block referenced by p or zero on error.
     */
    size_t sizeOf(void* p) nothrow
    {
        //need to check if interior pointer first
        return 0;
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     *
     * Params:
     *  p = A pointer to the root or the interior of a valid memory block or to
     *      null.
     *
     * Returns:
     *  Information regarding the memory block referenced by p or BlkInfo.init
     *  on error.
     */
    BlkInfo query(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket is null)
            return BlkInfo.init;

        return bucket.query(p);
    }

    /**
     * Retrieve statistics about garbage collection.
     *
     * Useful for debugging and tuning.
     */
    core.memory.GC.Stats stats() nothrow
    {
        //calculate used memory

        //calculate free memory

        return typeof(return).init;
    }

    /**
     * Add p to list of roots. If p is null, no operation is performed.
     *
     * Params:
     *  p = A pointer into a GC-managed memory block or null.
     */
    void addRoot(void* p) nothrow @nogc
    {
        roots.insertBack(Root(p));
    }

    /**
     * Remove p from list of roots. If p is null or is not a value
     * previously passed to addRoot() then no operation is performed.
     *
     * Params:
     *  p = A pointer into a GC-managed memory block or null.
     */
    void removeRoot(void* p) nothrow @nogc
    {
        foreach (ref r; roots)
        {
            if (r is p)
            {
                r = roots.back;
                roots.popBack();
                return;
            }
        }
        assert(false);
    }

    /**
     * Returns an iterator allowing roots to be traversed via a foreach loop.
     */
    @property RootIterator rootIter() @nogc
    {
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        foreach (ref r; roots)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    /**
     * Add range to scan for roots. If p is null or sz is 0, no operation is performed.
     *
     * Params:
     *  p  = A pointer to a valid memory address or to null.
     *  sz = The size in bytes of the block to add.
     *  ti = TypeInfo to describe the memory.
     */
    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        ranges.insertBack(Range(p, p + sz, cast() ti));
    }

    /**
     * Remove range from list of ranges. If p is null or does not represent
     * a value previously passed to addRange() then no operation is
     * performed.
     *
     * Params:
     *  p  = A pointer to a valid memory address or to null.
     */
    void removeRange(void* p) nothrow @nogc
    {
        foreach (ref r; ranges)
        {
            if (r.pbot is p)
            {
                r = ranges.back;
                ranges.popBack();
                return;
            }
        }
        assert(false);
    }

    /**
     * Returns an iterator allowing ranges to be traversed via a foreach loop.
     */
    @property RangeIterator rangeIter() @nogc
    {
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        foreach (ref r; ranges)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    /**
     * Run all finalizers in the code segment.
     *
     * Params:
     *  segment = address range of a code segment
     */
    void runFinalizers(in void[] segment) nothrow
    {

    }

    /**
     *  Checks if the GC is currently inside of a finalizer.
     *
     * Returns:
     *   True if isnide a finalizer, false if not.
     */
    bool inFinalizer() nothrow
    {
        return false;
    }

    /**
     * ScanRange describes a range of memory that is going to get scanned.
     *
     * It holds a pointer bitmap for the type that spans the range, and will be
     * scanned precisely if possible.
     */
    struct ScanRange
    {
        void* pbot, ptop; //the asterisk is left associative, these are both pointers
        size_t pointerMap;

        //this allows the ScanRange to be used in a foreach loop
        //the compiler will lower everything efficiently
        int opApply(int delegate(void*) nothrow dg ) nothrow
        {
            debug import core.stdc.stdio;
            int result = 0;

            void** memBot = cast(void**)pbot;
            void** memTop = cast(void**)ptop;

            if(pointerMap == size_t.max) //scan conservatively
            {
                for(; memBot < memTop; memBot++)
                {
                    //debug printf("scanning conservatively: %X -> %X\n", memBot, *memBot);

                    result = dg(*memBot);

                    if(result)
                        break;
                }
            }
            else //scan precisely with bsf
            {
                for(auto pos = bsf(pointerMap); pointerMap != 0; pointerMap &= ~(1 << pos))
                {

                    auto offset = pos*size_t.sizeof;

                    //debug printf("scanning precisely: %X -> %X\n",
                    //memBot+offset, *(memBot+offset));

                    result = dg(*(memBot+(pos*size_t.sizeof)));

                    if(result)
                        break;
                }
            }

            return result;
        }
    }

    /**
     * ScanStack describes a stack of ScanRange objects.
     *
     * The memory the stack uses is allocated upfront and assumed to be adequate.
     */
    struct ScanStack
    {
        void* memory;
        size_t count = 0;
        ScanRange[] array;
        size_t memSize;

        this(size_t size)
        {
            //allocate size amount of memory and set up array

            assert(size%ScanRange.sizeof == 0);//should always be wholly divisible

            memory = os_mem_map(size);
            memSize = size;

            //pretend this is an array of ScanRanges
            array = (cast(ScanRange*)memory)[0 .. (size/ScanRange.sizeof)];

        }
        ~this()
        {
            //free memory used by array
            os_mem_unmap(memory, memSize);
        }

        bool empty() nothrow
        {
            return count == 0;
        }

        //assume check for empty was done before this was called
        ScanRange pop() nothrow
        {
            return array[count--];
        }

        void push(ScanRange range) nothrow
        {
            array[++count] = range;
        }
    }

    //Start the stack at some large size
    //so that we hopefully never run into an overflow
    ScanStack scanStack;// = ScanStack(3*PAGE_SIZE);

    //copied from lifetime.d (more or less)
    void* getArrayStart(BlkInfo info) nothrow
    {
        enum : size_t
        {
            PAGESIZE = 4096,
            BIGLENGTHMASK = ~(PAGESIZE - 1),
            SMALLPAD = 1,
            MEDPAD = ushort.sizeof,
            LARGEPREFIX = 16, // 16 bytes padding at the front of the array
            LARGEPAD = LARGEPREFIX + 1,
            MAXSMALLSIZE = 256-SMALLPAD,
            MAXMEDSIZE = (PAGESIZE / 2) - MEDPAD
        }


        return info.base + ((info.size & BIGLENGTHMASK) ? LARGEPREFIX : 0);
    }


    void mark(void* pbot, void* ptop) scope nothrow
    {
        import core.stdc.stdio;


        //push the current range onto the stack to start the algorithm
        scanStack.push(ScanRange(pbot, ptop, size_t.max));

        while(!scanStack.empty())
        {
            ScanRange range = scanStack.pop();

            //printf("Scanning from %X to %X\n", range.pbot, range.ptop);

            foreach(void* ptr; range)
            {
                if( ptr >= memoryBottom && ptr < memoryTop)
                {
                    auto bucket = findBucket(ptr);

                    if(bucket is null)
                    {
                        continue;
                    }

                    if(!bucket.testMarkAndSet(ptr))
                    {
                        printf("Found %X\n", ptr);

                        if(bucket.getAttr(ptr) & BlkAttr.NO_SCAN)
                            continue;

                        //put in special scan here for array
                        //if we're scanning an array
                        if(bucket.arrayType)
                        {
                            BlkInfo arrInfo = bucket.query(ptr);
                            auto arrayPos = getArrayStart(arrInfo);
                            auto arrayEnd = arrayPos+bucket.objectSize;


                            ubyte pointerMapSize = bucket.pointerMapSize;

                            for(;arrayPos < arrayEnd; arrayPos+= pointerMapSize)//each object in the array
                            {
                                //push that object into the scan stack
                                scanStack.push(ScanRange(arrayPos, arrayPos + pointerMapSize, bucket.pointerMap));
                            }
                        }
                        else
                        {

                            scanStack.push(ScanRange(ptr, ptr + bucket.objectSize, bucket.pointerMap));
                        }
                    }
                }

            }
        }


    }

    int isMarked(void* p) scope nothrow
    {
        //return bucket.isMarked(p)?IsMarked.yes:IsMarked.no;
        return 0;
    }

    /**
     *  TypeManager manages the allocations for a specific type.
     */
    struct TypeManager
    {
        static TypedGC _gc;

        struct TypeNode
        {
            TypeBucket* bucket;
            TypeNode* next;
        }

        const TypeInfo info; //type info reference for hash comparison
        size_t pointerMap;
        size_t objectSize;
        ubyte ObjectsPerBucket;
        bool isArrayType;
        ubyte pointerMapSize;//used for array scanning

        //Mutex mutex;
        auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

        /// Linked list of all buckets managed for this type
        TypeNode* buckets;
        /// Bucket to be used when performing allocations (to avoid searching)
        TypeNode* allocateNode;

        /**
         * Construct a new TypeManager.
         *
         * This constructor also creates an empty bucket for allocations.
         */
        this(size_t objectSize, const TypeInfo ti) nothrow
        {
            info = ti;
            //Check to see if the type info describes an array type
            //this cast will fail if ti doesn't describe an array
            isArrayType = (cast(TypeInfo_Array) ti !is null) ? true : false;

            if(isArrayType)
            {
                //get the type info for the type the array holds
                bool valueIsPointerType;
                auto tinext = ti.next;
                this.objectSize = tinext.tsize;

                //check if the type of the array is a pointer or reference type
                if((cast(TypeInfo_Pointer) tinext !is null) ||
                   (cast(TypeInfo_Class) tinext !is null))
                {
                    //if the type is a pointer or reference type, we will always
                    //have one indirection to the actual object
                    pointerMap = 1;
                    pointerMapSize = size_t.sizeof;
                }
                else
                {
                    auto rtInfo = cast(const(size_t)*) tinext.rtInfo();
                    if (rtInfo !is null)
                    {
                        pointerMapSize = cast(ubyte)(rtInfo[0]);

                        int breaker = 0;
                        //copy the pointer bitmap embedded in the run time info
                        pointerMap = rtInfo[1];
                    }
                }


                ObjectsPerBucket = 1;



                CreateNewArrayBucket(buckets, objectSize);
            }
            else
            {
                auto rtInfo = cast(const(size_t)*) ti.rtInfo();
                if (rtInfo !is null)
                {
                    //copy the pointer bitmap embedded in the run time info
                    pointerMap = rtInfo[1];
                }
                this.objectSize = objectSize;
                ObjectsPerBucket = getObjectsPerBucket(objectSize);

                //initialize the linked list with a node and bucket
                createNewBucket(buckets);
            }




            //mutex.init();
        }


        ubyte getObjectsPerBucket(size_t objectSize) nothrow
        {
            if(objectSize < 64)      //small
            {
                return 32;
            }
            else if(objectSize < 128)//medium
            {
                return 16;
            }
            else if(objectSize < 256)//big
            {
                return 8;
            }
            else if(objectSize < 512)//very big
            {
                return 4;
            }
            else                     //HUGE
            {
                return 1;
            }
        }

        /**
         * Creates a new TypeBucket for this type and initializes it.
         *
         * In addition to creating the bucket itself, this function creates a
         * TypeNode for the new bucket and assigns it to allocateNode. It also
         * inserts a new SearchNode containing the new bucket into the search
         * tree.
         *
         * Params:
         *  node = A reference to the end of the linked list.
         */
        void createNewBucket(ref TypeNode* node) nothrow
        {
            //create TypeNode
            node = cast(TypeNode*)_gc.salloc(TypeNode.sizeof);
            node.next = null;

            //Create SearchNode
            auto newSearchNode = cast(SearchNode*)_gc.salloc(SearchNode.sizeof);
            newSearchNode.left = null;
            newSearchNode.right = null;

            //create TypeBucket
            auto newBucket = cast(TypeBucket*)_gc.salloc(TypeBucket.sizeof);

            //initialize the bucket
            *(newBucket) = TypeBucket(objectSize,ObjectsPerBucket, pointerMap);


            node.bucket = newBucket;
            newSearchNode.bucket = newBucket;

            allocateNode = node;
            _gc.searchNodeInsert(newSearchNode);
        }



        /**
         * Creates a new TypeBucket for an array and initializes it.
         *
         * In addition to creating the bucket itself, this function creates a
         * TypeNode for the new bucket and assigns it to allocateNode. It also
         * inserts a new SearchNode containing the new bucket into the search
         * tree.
         *
         * Params:
         *  node = A reference to the end of the linked list.
         *  size = the requested size of memory for the array.
         */
        void CreateNewArrayBucket(ref TypeNode* node, size_t size) nothrow
        {
            //create TypeNode
            node = cast(TypeNode*)_gc.salloc(TypeNode.sizeof);
            node.next = null;

            //Create SearchNode
            auto newSearchNode = cast(SearchNode*)_gc.salloc(SearchNode.sizeof);
            newSearchNode.left = null;
            newSearchNode.right = null;

            //create TypeBucket
            auto newBucket = cast(TypeBucket*)_gc.salloc(TypeBucket.sizeof);

            //calulate the full size of the array. This adds length to the array
            //to make it appendable

            //array size = requested size + (approximate length * 0.25 * object size)

            size_t padding = ((size/objectSize) >> 2) * objectSize;

            size_t arraySize = size + padding;

            //initialize the bucket
            *(newBucket) = TypeBucket(arraySize,ObjectsPerBucket, pointerMap, pointerMapSize);

            //let the bucket know it is an array
            newBucket.arrayType = true;


            node.bucket = newBucket;
            newSearchNode.bucket = newBucket;

            allocateNode = node;
            _gc.searchNodeInsert(newSearchNode);
        }


        //finds a bucket and grabs memory from it
        void* alloc(uint bits) nothrow
        {
            mutex.lock();
            //will call mutex.unlock() at the end of the scope
            scope (exit)
                mutex.unlock();

            //make sure we have a bucket that can store new objects
            while (allocateNode.bucket.isFull())
            {
                if (allocateNode.next is null)
                {
                    //creates a new TypeNode and will assign it to allocateNode
                    createNewBucket(allocateNode.next);
                    break;
                }

                allocateNode = allocateNode.next;
            }
            int test = 0;
            return allocateNode.bucket.alloc(bits);
        }


        BlkInfo qalloc(uint bits) nothrow
        {
            BlkInfo ret;
            ret.base = alloc(bits);
            ret.size = allocateNode.bucket.objectSize;
            ret.attr = bits;

            return ret;
        }

    }

    /**
     *  UntypedManager manages the allocations for all untyped data.
     */
    struct UntypedManager
    {
        static TypedGC _gc;

        struct TypeNode
        {
            TypeBucket* bucket;
            TypeNode* next;
        }

        auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

        /// Linked list of all buckets managed for this type
        TypeNode* buckets;
        /// Bucket to be used when performing allocations (to avoid searching)
        TypeNode* allocateNode;

        /**
         * Construct a new TypeManager.
         */
        void initialize() nothrow
        {
        }


        /**
         * Creates a new TypeBucket for this type and initializes it.
         *
         * In addition to creating the bucket itself, this function creates a
         * TypeNode for the new bucket and assigns it to allocateNode. It also
         * inserts a new SearchNode containing the new bucket into the search
         * tree.
         *
         * Params:
         *  node = A reference to the end of the linked list.
         */
        void createNewBucket(ref TypeNode* node, size_t size, uint bits) nothrow
        {
            //create TypeNode
            node = cast(TypeNode*)_gc.salloc(TypeNode.sizeof);
            node.next = null;

            //Create SearchNode
            auto newSearchNode = cast(SearchNode*)_gc.salloc(SearchNode.sizeof);
            newSearchNode.left = null;
            newSearchNode.right = null;

            //create TypeBucket
            auto newBucket = cast(TypeBucket*)_gc.salloc(TypeBucket.sizeof);

            //if(bits & BlkAttr.APPENDABLE)

            //initialize the bucket
            *(newBucket) = TypeBucket(size,1, size_t.max);


            node.bucket = newBucket;
            newSearchNode.bucket = newBucket;

            allocateNode = node;
            _gc.searchNodeInsert(newSearchNode);
        }

        //finds a bucket and grabs memory from it
        void* alloc(size_t size, uint bits) nothrow
        {
            mutex.lock();
            //will call mutex.unlock() at the end of the scope
            scope (exit)
                mutex.unlock();


            if(buckets is null)
            {
                createNewBucket(buckets,size, bits);
            }
            else
            {
                createNewBucket(allocateNode.next, size, bits);
            }


            return allocateNode.bucket.alloc(bits);
        }

    }


    /**
     * TypeBucket is a structure that defines a bucket holding a single type.
     *
     * This structure uses information about the type in order to perform some cool
     * things.
     */
    struct TypeBucket
    {
        static TypedGC _gc;

        /// The number of objects held by the bucket
    private:
        void* memory; //a pointer to the memory used by this bucket to hold the objects
        size_t objectSize; //size of each object
        size_t pointerMap; //the bitmap describing what words are pointers
        ubyte* attributes; //the attributes per object
        uint freeMap; //the bitmap of all free objects in this bucket
        uint markMap; //the bitmap of all object that have been found during a collection
        ubyte numberOfObjects;
        bool arrayType;
        ubyte pointerMapSize;//used for array scanning
        //space for one more byte for this allignment

    public:

        /// TypeBucket Constructor
        this(size_t size, ubyte numberOfObjects, size_t pointerMap, ubyte pointerMapSize = 0) nothrow
        {
            objectSize = size;
            this.numberOfObjects = numberOfObjects;

            freeMap = 0;
            markMap = 0;

            this.pointerMap = pointerMap;
            this.pointerMapSize = pointerMapSize;


            memory = _gc.halloc(numberOfObjects*objectSize);
            attributes = cast(ubyte*)_gc.salloc(ubyte.sizeof * numberOfObjects);
        }

        /**
         * Cleans up the object held by the bucket.
         *
         * Since the memory the bucket uses is allocated elsewhere, it does not free
         * it.
         */
        void dtor()
        {
            uint numObjs = numberOfObjects;

            while (freeMap != 0)
            {
                auto pos = bsf(freeMap);


                uint attr = attributes[pos];


                if (attributes[pos] & BlkAttr.FINALIZE || attributes[pos] & BlkAttr.STRUCTFINAL)
                {
                    rt_finalizeFromGC(memory + pos * objectSize, objectSize, attributes[pos]);
                }

                freeMap &= ~(1 << pos);
            }
        }

        /**
         * Checks the freemap to see if this bucket is full.
         */
        bool isFull() nothrow
        {
            final switch(numberOfObjects)
            {
                case 32:
                    return freeMap == uint.max;
                case 16:
                    return freeMap == cast(uint)ushort.max;
                case 8:
                    return freeMap == cast(uint)ubyte.max;
                case 4:
                    return freeMap == cast(uint)0b1111;
                case 1:
                    return freeMap == cast(uint)1;
            }
        }

        /**
         * Provide some memory for the GC to create a new object.
         */
        void* alloc(uint bits) nothrow
        {
            //assume we're in a correct state to allocate

            auto pos = bsf(cast(size_t)~freeMap);

            //Current attributes use at most 6 bits, so we can use a smaller
            //type internally
            attributes[pos] = cast(ubyte) bits;
            freeMap |= (1 << pos);

            void* actualLocation = memory + pos * objectSize;

            return actualLocation;
        }

        /**
         * Run the finalizer on the object stored at p, and then sets it as free in
         * the freeMap.
         *
         * This function assumes that the pointer is within this bucket.
         */
        void free(void* p) nothrow
        {

            //find the position, run finalizer, clear bits

            auto pos = (p - memory) / objectSize;

            //check if needs finalization
            if (attributes[pos] & BlkAttr.FINALIZE || attributes[pos] & BlkAttr.STRUCTFINAL)
            {
                rt_finalizeFromGC(memory + pos * objectSize, objectSize, attributes[pos]);
            }

            freeMap &= ~(1 << pos);
        }

        void* addrOf(void* p) nothrow
        {
            //assume that p is one of these objects
            return memory + ((p - memory) / objectSize) * objectSize;
        }

        BlkInfo query(void* p) nothrow
        {
            BlkInfo ret;

            auto pos = (p - memory) / objectSize;

            ret.base = memory + pos * objectSize;
            ret.size = objectSize;
            ret.attr = attributes[pos];

            return ret;
        }

        void sweep() nothrow
        {
            uint markBit = 1;

            //run finalizers for all non-marked objects (if they need it)

            //mark those objects as freed
        }

        /**
         * Checks if a pointer lies within a chunk of memory that has been marked
         * during a GC collection.
         *
         * This function assumes that the pointer is within this bucket.
         *
         * Returns:
         *  True if p is marked, otherwise returns false.
         */
        bool isMarked(void* p) nothrow
        {
            uint markBit = 1 << (p - memory) / objectSize;

            return (markMap & markBit) ? true : false;
        }

        /**
         * Check if the mark bit is set for this pointer, and sets it if not set.
         *
         * This function assumes that the pointer is within this bucket.
         *
         * Returns:
         *  True if the pointer was already marked, false if it wasn't.
         */
        bool testMarkAndSet(void* p) nothrow
        {
            uint markBit = 1 << (p - memory) / objectSize;

            if (markMap & markBit)
                return true;

            markMap |= markBit;
            return false;
        }

        /**
         * Checks to see if a pointer to something points to an object in this
         * bucket.
         */
        bool containsObject(void* p) nothrow
        {
            if (p >= memory && p < memory + objectSize * numberOfObjects)
                return true;

            return false;
        }

        uint getAttr(void* p) nothrow
        {
            return attributes[(p - memory) / objectSize];
        }

        uint setAttr(void* p, uint mask) nothrow
        {
            attributes[(p - memory) / objectSize] |= mask;

            return attributes[(memory - p) / objectSize];
        }

        uint clrAttr(void* p, uint mask) nothrow
        {
            attributes[(p - memory) / objectSize] &= ~mask;

            return attributes[(memory - p) / objectSize];
        }
    }
}



