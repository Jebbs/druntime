/**
 * Contains a garbage collection implementation that organizes memory based on
 * the type information.
 *
 */
module gc.impl.type.gc;

import core.bitop; //bsf
import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.thread;

import gc.config;
import gc.gcinterface;
import gc.impl.type.memory;
import gc.impl.type.typemanager;
import gc.impl.type.typehash;
import gc.impl.type.scan;

import rt = rt.util.container.array;
import core.internal.spinlock;

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


__gshared GCAllocator allocator;


/**
 * The Typed GC organizes memory based on type.
 */
class TypeGC : GC
{
    /// Array of roots to search for pointers.
    rt.Array!Root roots;
    /// Array of ranges of data to search for pointers.
    rt.Array!Range ranges;

    uint disabled;
    TypeHash typeHash;

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

        if (config.gc != "type")
            return;

        allocator.initialize();
        TypeManager.allocator = &allocator;

        auto p = cstdlib.malloc(__traits(classInstanceSize, TypeGC));
        if (!p)
            onOutOfMemoryErrorNoGC();

        auto init = typeid(TypeGC).initializer();
        assert(init.length == __traits(classInstanceSize, TypeGC));
        auto instance = cast(TypeGC) memcpy(p, init.ptr, init.length);
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
        if (config.gc != "type")
            return;

        auto instance = cast(TypeGC) gc;
        destroy(instance);
        cstdlib.free(cast(void*) instance);

        debug
        {
            import core.stdc.stdio;

            //printf("press enter to continue...\n");
            //getchar();
        }
    }

    /**
     * Constructor for the Typed GC.
     */
    this()
    {
        import core.stdc.string: memset;

        typeHash.initialize();

        //start the stack with tons of memory so it doesn't overflow (I hope)
        scanStack = ScanStack(3*PAGE_SIZE);
    }

    ~this()
    {
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
        disabled--;
    }

    /**
     * Disable the GC. The GC may still run if it deems necessary.
     */
    void disable()
    {
        disabled++;
    }

    /**
     * Begins a full collection, scanning all stack segments for roots.
     *
     * Returns:
     *  The number of pages freed.
     */
    void collect() nothrow
    {
        //disable threads
        thread_suspendAll();

        //prepare for scanning
        prepare();

        //scan and mark
        thread_scanAll(&mark);

        //scan through all roots
        foreach (root; roots)
        {
            mark(cast(void*)&root.proot, cast(void*)(&root.proot + 1));
        }

        //scan through all ranges
        foreach (range; ranges)
        {
            mark(range.pbot, range.ptop);
        }

        //resume threads
        thread_processGCMarks(&isMarked);
        thread_resumeAll();

        //get outa here, garbage!
        sweep();
    }

    /**
     * Begins a full collection while ignoring all stack segments for roots.
     */
    void collectNoStack() nothrow
    {
        //disable threads
        thread_suspendAll();

        //prepare for scanning
        prepare();

        //scan through all roots
        foreach (root; roots)
        {
            mark(cast(void*)&root.proot, cast(void*)(&root.proot + 1));
        }

        //scan through all ranges
        foreach (range; ranges)
        {
            mark(range.pbot, range.ptop);
        }

        //resume threads
        thread_processGCMarks(&isMarked);
        thread_resumeAll();
    }

    /**
     * Minimize free space usage.
     */
    void minimize() nothrow
    {
        //do nothing for now
        //what can we do, honestly?
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

        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
        {
            return manager.getAttr(p);
        }

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
        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
        {
            return manager.setAttr(p, cast(ubyte)mask);
        }

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
        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
        {
            return manager.clrAttr(p, cast(ubyte)mask);
        }

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
        if(size == 0)
            return null;

        auto type = typeHash.getTypeManager(size, ti);

        if(type.requiresCollection())
            collect();

        //Attribuytes only use 6 bits, so this saves us memory
        return type.alloc(size, cast(ubyte)bits);
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
        if(size == 0)
            return BlkInfo();

        auto type = typeHash.getTypeManager(size, ti);

        if(type.requiresCollection())
            collect();

        //Attribuytes only use 6 bits, so this saves us memory
        return type.qalloc(size, cast(ubyte)bits);
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
        import core.stdc.string : memcpy;

        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager is null)
            return p;

        if(manager.requiresCollection())
            collect();

        //Attribuytes only use 6 bits, so this saves us memory
        return manager.realloc(p, size, cast(ubyte)bits);
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

        //because of the way allocations currently work,
        //extending is diabled

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
        //create some raw memory for type buckets to use?

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
        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
            manager.free(p);
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
    void* addrOf(void* p) nothrow @nogc
    {
        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
            return manager.addrOf(p);

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
    size_t sizeOf(void* p) nothrow @nogc
    {
        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
            return manager.sizeOf(p);

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
        auto manager = typeHash[allocator.typeLookup(p)];

        if(manager)
            return manager.query(p);

        return BlkInfo();
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
        foreach(manager;typeHash)
        {
            manager.prepare();
        }
    }

    void sweep() nothrow
    {
        foreach(manager;typeHash)
        {
            manager.sweep();
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
        scanStack.push(ScanRange(pbot, ptop, cast(size_t*)1));

        while(!scanStack.empty())
        {
            ScanRange range = scanStack.pop();

            printf("Scanning from %X to %X\n", range.pbot, range.ptop);

            foreach(void* ptr; range)
            {
                auto heapMem = ptr;

                if(heapMem == cast(void*)0x7fffb70454d8)
                {
                    int breaky = 0;
                }

                auto tindex = allocator.typeLookup(heapMem);

                if(tindex < 0)
                    continue;


                auto manager = typeHash[tindex];

                if(manager is null)
                    continue;

                if(!manager.testMarkAndSet(heapMem))
                {
                    printf("Found %X\n", heapMem);
                    if(manager.getAttr(heapMem) & BlkAttr.NO_SCAN)
                        continue;


                    manager.scan(scanStack, heapMem);
                }
            }
        }

    }

    int isMarked(void* p) scope nothrow
    {
        auto manager = typeHash[allocator.typeLookup(p)];
        if(manager)
            return manager.isMarked(p)?IsMarked.yes:IsMarked.no;

        return 0;
    }
}
