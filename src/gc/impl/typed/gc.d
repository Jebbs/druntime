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
import gc.impl.typed.systemalloc;
import gc.impl.typed.bucketavl;
import gc.impl.typed.typebucket;

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
    //void* heapBottom, heapTop;


    uint hashSize = 101;
    TypeManager[] hashArray;
    UntypedManager untypedManager;

    struct ListNode(T)
    {
        T object;
        ListNode!(T)* next;
    }

    alias ManagerNode = ListNode!(TypeManager*);

    ManagerNode* managers;
    ManagerNode* lastManager;



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

                if(managers is null)
                {
                    managers = cast(ManagerNode*)salloc(ManagerNode.sizeof);
                    managers.object = &hashArray[pos];
                    managers.next = null;
                    lastManager = managers;
                }
                else
                {
                    lastManager.next = cast(ManagerNode*)salloc(ManagerNode.sizeof);
                    lastManager = lastManager.next;
                    lastManager.object = &hashArray[pos];
                    lastManager.next = null;
                }

                return &(hashArray[pos]);
            }
            else if(hashArray[pos].info is ti)
            {
                return &(hashArray[pos]);
            }

            attempts++;
        }
    }

    BucketAVL buckets;

    //recursive function for finalizing all buckets in the binary tree
    void finalizeBuckets() nothrow
    {
        foreach(bucket; buckets)
        {
            bucket.dtor();
        }
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

        //initialize the internal allocation system
        AllocSystem.initialize();

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


        //finalize the internal allocation system
        AllocSystem.finalize();

        debug
        {
            import core.stdc.stdio;

            printf("press enter to continue...\n");
            getchar();
        }
    }



    /**
     * Constructor for the Typed GC.
     */
    this()
    {
        import core.stdc.string: memset;

        //heapBottom = currentChunk.start;
        //heapTop = currentChunk.start + currentChunk.chunkSize;

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
        finalizeBuckets();

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

        prepare();

        foreach(bucket; buckets)
        {
            //bucket.prepare();
        }

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
        auto bucket = buckets.findBucket(p);

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
     * Prepare the GC for the marking process.
     *
     * This function will go through and informs all TypeManagers that they need
     * to sweep next time they allocate.
     */
    void prepare() nothrow
    {
        for(auto cur = managers; cur !is null; cur = cur.next)
        {
            cur.object.prepare();
        }
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
                for(auto pos = bsf(pointerMap); pointerMap != 0; pointerMap &= ~(1 << pos), pos = bsf(pointerMap))
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
        import core.stdc.stdio;

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
            debug
            {
                //printf("Stack popped: %d elements\n", count-1);
            }
            return array[count--];
        }

        void push(ScanRange range) nothrow
        {
            debug
            {
                //printf("Stack pusheded: %d elements\n", count+1);
            }
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
                auto bucket = buckets.findBucket(ptr);

                if(bucket is null)
                {
                    continue;
                }

                if(!bucket.testMarkAndSet(ptr))
                {
                    //printf("Found %X\n", ptr);
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
        bool needsSweeping;

        //Mutex mutex;
        auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

        /// Linked list of all buckets managed for this type
        TypeNode* buckets;
        /// Bucket to be used when performing allocations (to avoid searching)
        TypeNode* allocateNode;
        //a freelist to be used for array types
        TypeNode* freeList;

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
            node = cast(TypeNode*)salloc(TypeNode.sizeof);
            node.next = null;


            //create TypeBucket
            auto newBucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

            //initialize the bucket
            *(newBucket) = TypeBucket(objectSize,ObjectsPerBucket, pointerMap);


            node.bucket = newBucket;

            allocateNode = node;
            _gc.buckets.insert(newBucket);
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
            node = cast(TypeNode*)salloc(TypeNode.sizeof);
            node.next = null;


            //create TypeBucket
            auto newBucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

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

            allocateNode = node;
            _gc.buckets.insert(newBucket);
        }

        //finds a bucket and grabs memory from it
        void* alloc(uint bits) nothrow
        {
            mutex.lock();
            //will call mutex.unlock() at the end of the scope
            scope (exit)
                mutex.unlock();

            if(needsSweeping)
                sweep();

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

        void prepare() nothrow
        {
            needsSweeping = true;
        }

        void sweep() nothrow
        {
            TypeNode start;
            start.next = buckets;
            for(auto cur = &start; cur.next !is null;)
            {
                //sweep the buckets
                cur.next.bucket.sweep();
                if(isArrayType && cur.next.bucket.empty())
                {

                    // push into a free list if empty
                    TypeNode* temp = cur.next;
                    cur.next = cur.next.next;

                    if(freeList is null)
                        temp.next = null;
                    else
                        temp.next = freeList;

                    freeList = temp;
                }
                else
                {
                    cur = cur.next;
                }
            }

            if(!isArrayType)
            {
                //set the allocation bucket to the bucket in the list
                allocateNode = buckets;
            }

            needsSweeping = false;
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
            node = cast(TypeNode*)salloc(TypeNode.sizeof);
            node.next = null;

            //create TypeBucket
            auto newBucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

            //if(bits & BlkAttr.APPENDABLE)

            //initialize the bucket
            *(newBucket) = TypeBucket(size,1, size_t.max);


            node.bucket = newBucket;

            allocateNode = node;
            _gc.buckets.insert(newBucket);
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

}
