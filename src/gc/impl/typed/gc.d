/**
 * Contains a garbage collection implementation that organizes memory based on
 * the type information.
 *
 */

module gc.impl.typed.gc;

import core.bitop; //bsf
import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.thread;

import gc.config;
import gc.gcinterface;

import rt.util.container.array;

//static import core.memory;

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

    /// The holder of buckets
    BinTree buckets;

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
        instance.Dtor();
        cstdlib.free(cast(void*) instance);
    }

    /**
     * Constructor for the Typed GC.
     */
    this()
    {
    }

    /**
     * Destructor for the Typed GC.
     */
    void Dtor()
    {
        buckets.dtor();
        roots.reset();
        ranges.reset();
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

        buckets.max = cast(void*)0;
        buckets.min = cast(void*)size_t.max;

        buckets.findMaxMin(buckets.min, buckets.max);

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

        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return 0;

        return bucket.getAttr(p);
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

        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return 0;

        return bucket.setAttr(p, mask);
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
        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return 0;

        return bucket.clrAttr(p, mask);
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
        TypeBucket* typeBucket = buckets.retrieve(size, ti);

        //will need more info during actual allocation

        return typeBucket.alloc(bits);
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
        retval.base = malloc(size, bits, ti);
        retval.size = size;
        retval.attr = bits;
        return retval;
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

        TypeBucket* typeBucket = buckets.retrieve(size, ti);


        p = cstdlib.realloc(p, size);

        if (size && p is null)
            onOutOfMemoryErrorNoGC();
        return p;
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

        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return;

        bucket.free(p);
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
        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return null;

        return bucket.addrOf(p);
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

        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return 0;

        return bucket.objectSize;
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
        TypeBucket* bucket = buckets.retrieve(p);

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

    void mark(void *pbot, void *ptop) scope nothrow
    {
        import core.stdc.stdio;
        void **p1 = cast(void **)pbot;
        void **p2 = cast(void **)ptop;

        for(; p1 < p2; p1++)
        {
            auto pointer = *p1;
            if(pointer < buckets.min || pointer >= buckets.max)
                continue;

            printf("pointer = %X\n", pointer);

            //find out if this points to something of ours
            auto bucket = buckets.retrieve(pointer);
            if(bucket is null)
                continue;

            //test if interior pointer


            if(!bucket.testMarkAndSet(pointer))
            {
                //printf("pointer = %X\n", p1);

                printf("Marking a new pointer.\n");

                uint attr = bucket.getAttr(pointer);
                uint noScan = BlkAttr.NO_SCAN;


                if((bucket.getAttr(pointer) & BlkAttr.NO_SCAN))
                    continue;

//                printf("These assholes are pointers!\n");

                uint pointerMap = bucket.pointerMap;
                void* start = pointer;

                while(pointerMap != 0)
                {
                    uint pos = bsf(pointerMap);

                    pointerMap &= ~(1 << pos);
                    void* ptr = pointer + pos*size_t.sizeof;

                    printf("Internal ptr to scan: %X\n", ptr);

                }
            }
        }


    }

    int isMarked(void* p) scope nothrow
    {
        TypeBucket* bucket = buckets.retrieve(p);

        if(bucket is null)
            return IsMarked.unknown;

        return bucket.isMarked(p)?IsMarked.yes:IsMarked.no;
    }
}

/**
 * A quick binary tree for getting things up and running.
 *
 * This binary tree is special in that the retrieve function inserts if a given
 * bucket isn't contained. In this way, we always assume that we have a bucket
 * ready.
 */
struct BinTree
{
    private struct Node
    {
        TypeBucket* bucket;
        Node* left;
        Node* right;
    }
    private Node* root = null;

    void* min;
    void* max;

    void dtor()
    {
        if(root is null)
            return;

        dtorHelper(root);
    }

    ///Retrieve the TypeBucket used to allocate a specific type.
    TypeBucket* retrieve(size_t size, const TypeInfo ti) nothrow
    {

        //what if ti is null?
        //will need to considedr this (for GC allocation of raw memory)

        if(root is null)
        {
            root = createNewNode(size, ti);

            return root.bucket;
        }

        return retrieveHelper(root, size, ti);
    }

    ///Retrieve the TypeBucket used to allocate a specific type.
    TypeBucket* retrieve(void* p) nothrow
    {
        if(root is null)
            return null;

        return retrieveHelper(root, p);
    }

    /// A helper function for the binary tree traversal and alloc of new nodes.
    private TypeBucket* retrieveHelper(Node* node, size_t size,
                                       const TypeInfo ti) nothrow
    {
        //is each hash actually unique?
        //assume yes for now, and fix during design period (hash that shit)

        if(node.bucket.id == ti.toHash())
        {
            return node.bucket;
        }
        else if(node.bucket.id < ti.toHash())
        {
            if(node.right is null)
            {
                //create and return

                node.right = createNewNode(size, ti);
                return node.right.bucket;
            }

            return retrieveHelper(node.right, size, ti);
        }
        else
        {
            if(node.left is null)
            {
                //create and return

                node.left = createNewNode(size, ti);
                return node.left.bucket;
            }

            return retrieveHelper(node.left, size, ti);
        }

    }

    /// A helper function for the binary tree traversal to find the bucket containing p.
    private TypeBucket* retrieveHelper(Node* node, void* p) nothrow
    {

        //wow, this is really bad
        //will be better when I have more time to think about it

        //currently no way to narrow it down, but will probably want to do some
        //kind of tree

        //possible to narrow it down using the pointer value?
        //Similar to hashing?

        if(node is null)
            return null;

        TypeBucket* bucket = null;


        if(node.bucket.containsObject(p))
            return node.bucket;

        bucket = retrieveHelper(node.left, p);

        if(!bucket)
            bucket = retrieveHelper(node.right, p);

        if(bucket)
            return bucket;

        return null;
    }

    private Node* createNewNode(size_t size, const TypeInfo ti)
        nothrow
    {
        Node* newNode = cast(Node*)cstdlib.malloc(Node.sizeof);

        //size of the bucket plus size of 32 objects
        void* memory = cstdlib.malloc(TypeBucket.sizeof + size*32);

        newNode.bucket = cast(TypeBucket*)memory;
        memory+=TypeBucket.sizeof;

        newNode.bucket.initialize(size, ti, memory);

        newNode.left = null;
        newNode.right = null;

        return newNode;
    }

    private void dtorHelper(Node* node)
    {
        if(node is null)
            return;

        dtorHelper(node.left);
        dtorHelper(node.right);

        node.bucket.dtor();

        cstdlib.free(node.bucket);
        cstdlib.free(node);
    }

    void findMaxMin(ref void* min, ref void* max) nothrow
    {
        fmmHelper(root, min, max);
    }

    private void fmmHelper(Node* node, ref void* min, ref void* max) nothrow
    {
        if(node is null)
            return;

        if(min>node.bucket.memory)
            min = node.bucket.memory;

        if(max < node.bucket.memory+32*node.bucket.objectSize)
            max = node.bucket.memory+32*node.bucket.objectSize;

        fmmHelper(node.left, min, max);
        fmmHelper(node.right, min, max);
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
    /// The number of objects held by the bucket
    static immutable ObjectsPerBucket = 32;
    private:
        size_t id;//identifier
        ubyte objectSize;//size of each object
        uint freeMap;//the bitmap of all free objects in this bucket
        uint markMap;//the bitmap of all object that have been found during a collection
        uint pointerMap;//the bitmap describing what words are pointers
        uint[ObjectsPerBucket] attributes;//the attributes per object
        TypeBucket* nextBucket; //the next bucket of the same type (linked list style)

        //one of these might be better than the other, we'll see
        void* memory; //a pointer to the memory used by this bucket to hold the objects
        void*[] objects; //a slice of the memory for easy access to each object

    public alias id this;

    public:

    /**
     * Initializes the Type bucket.
     *
     * This function is called instead of the constructor because we are using
     * malloc to get the memory for this object.
     */
    void initialize(size_t size, const TypeInfo ti, void* memory) nothrow
    {
        // do the stuff
        id = ti.toHash();

        //this is ok for now because we will make sure objectSize is large enough
        //to hold the actual size of an object later
        objectSize = cast(typeof(objectSize))size;

        freeMap = 0;
        markMap = 0;

        auto rtInfo = cast(const(size_t)*)ti.rtInfo();
        if(rtInfo !is null)
        {
            //copied from previos work
            //pointerBitmapSize = cast(ubyte)(*rtInfo)/(void*).sizeof;

            rtInfo++;

            //the pointer map can be scanned using a bsf instruction
            pointerMap = cast(uint)rtInfo[0];
            int i = 0;
        }

        nextBucket = null;

        this.memory = memory;
    }

    /**
     * Cleans up the object held by the bucket.
     *
     * Since the memory the bucket uses is allocated elsewhere, it does not free
     * it.
     */
    void dtor()
    {
        while(freeMap != 0)
        {
            auto pos = bsf(freeMap);

            if(attributes[pos] & BlkAttr.FINALIZE ||
               attributes[pos] & BlkAttr.STRUCTFINAL)
            {
                rt_finalizeFromGC(memory + pos*objectSize, objectSize,
                                  attributes[pos]);
            }

            freeMap &= ~(1 << pos);
        }
    }

    /**
     * Provide some memory for the GC to create a new object.
     */
    void* alloc(uint bits) nothrow
    {
        //assume we're in a correct state to allocate

        int objectPosition = bsf(cast(size_t)~freeMap);

        attributes[objectPosition] = bits;
        freeMap |= (1<<objectPosition);

        void* actualLocation = memory + objectPosition*objectSize;

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

        uint objectPosition = cast(uint)(p - memory)/objectSize;

        //check if needs finalization
        if(attributes[objectPosition] & BlkAttr.FINALIZE ||
           attributes[objectPosition] & BlkAttr.STRUCTFINAL)
        {
            rt_finalizeFromGC(memory + objectPosition*objectSize, objectSize,
                          attributes[objectPosition]);
        }


        freeMap &= ~(1 << objectPosition);
    }

    void* addrOf(void* p) nothrow
    {
        //assume that p is one of these objects
        return memory + ((p - memory)/objectSize) * objectSize;
    }

    BlkInfo query(void* p) nothrow
    {
        BlkInfo ret;

        uint objectPosition = cast(uint)(p - memory)/objectSize;

        ret.base = memory + objectPosition*objectSize;
        ret.size = objectSize;
        ret.attr = attributes[objectPosition];

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
        uint markBit = 1 << (p - memory)/objectSize;

        return (markMap & markBit)?true:false;
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
        uint markBit = 1 << (p - memory)/objectSize;

        if(markMap & markBit)
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

        void* bMin = memory;
        void* bMax = memory + objectSize*ObjectsPerBucket;

        if(p >= memory && p < memory + objectSize*ObjectsPerBucket)
            return true;
        
        if(nextBucket is null)
            return false;

        return nextBucket.containsObject(p);
    }

    uint getAttr(void* p) nothrow
    {
        return attributes[(p - memory)/objectSize];
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        attributes[(p - memory)/objectSize] |= mask;

        return attributes[(memory - p)/objectSize];
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        attributes[(p - memory)/objectSize] &= ~mask;

        return attributes[(memory - p)/objectSize];
    }


    auto getPointers(void* p) nothrow
    {
        struct PointerIterator
        {
            void* start;
            size_t pMap;


            int opApply(scope int delegate(void*) nothrow dg) nothrow
            {
                int result = 0;

                while(pMap !=0)
                {
                    auto pos = bsf(pMap);

                    result = dg(p + pos*size_t.sizeof);
                }

                return result;
            }
        }

        return PointerIterator(p, pointerMap);
    }
}
