/**
 * Contains a garbage collection implementation that organizes memory based on
 * the type information.
 *
 */
module gc.impl.type_mt.gc;

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

import gc.impl.type.gc;
import core.internal.gcthread;

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
__gshared TypeGC_MT collector;


/**
 * The Typed GC organizes memory based on type.
 */
class TypeGC_MT : TypeGC
{
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);
    bool collecting = false;

    GCThread collectThread;


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

        if (config.gc != "type_mt")
            return;

        auto p = cstdlib.malloc(__traits(classInstanceSize, TypeGC_MT));
        if (!p)
            onOutOfMemoryErrorNoGC();

        auto init = typeid(TypeGC_MT).initializer();
        assert(init.length == __traits(classInstanceSize, TypeGC_MT));
        auto instance = cast(TypeGC_MT) memcpy(p, init.ptr, init.length);
        instance.__ctor();

        gc = instance;
        collector = instance;
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
        if (config.gc != "type_mt")
            return;

        auto instance = cast(TypeGC_MT) gc;
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
        super();
    }

    /**
     * Begins a full collection, scanning all stack segments for roots.
     *
     * Returns:
     *  The number of pages freed.
     */
    override void collect() nothrow
    {
        //disable threads
        //thread_suspendAll();

        mutex.lock();
        if(collecting)
        {
            mutex.unlock();
            return;
        }

        collecting = true;
        mutex.unlock();

        collectThread.create(&collectFunc);
    }


    /**
     * Begins a full collection while ignoring all stack segments for roots.
     */
    override void collectNoStack() nothrow
    {
        //disable threads
        //thread_suspendAll();

        mutex.lock();
        if(collecting)
        {
            mutex.unlock();
            bool waiting = true;

            while(waiting)
            {
                mutex.lock();
                if(!collecting)
                    waiting = false;
                mutex.unlock();
            }
            mutex.lock();
        }

        collecting = true;
        mutex.unlock();

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
        thread_suspendAll();
        thread_processGCMarks(&isMarked);
        thread_resumeAll();

        mutex.lock();
        collecting = false;
        mutex.unlock();
    }


    void markSetup(void* pbot, void* ptop) scope nothrow
    {
        import core.stdc.stdio;

        //push the current range onto the stack to start the algorithm
        scanStack.push(ScanRange(pbot, ptop, cast(size_t*)1));

        while(!scanStack.empty())
        {
            ScanRange range = scanStack.pop();

            //printf("Scanning from %X to %X\n", range.pbot, range.ptop);

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

/*
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
                    //printf("Found %X\n", heapMem);
                    if(manager.getAttr(heapMem) & BlkAttr.NO_SCAN)
                        continue;


                    manager.scan(scanStack, heapMem);
                }
            }
        }

    }
    */

}

extern(C) void* collectFunc(void*) nothrow
    {
        //prepare for scanning
        collector.prepare();

        //scan and mark
        thread_scanAll(&(collector.mark));

        //scan through all roots
        foreach (root; collector.roots)
        {
            collector.mark(cast(void*)&root.proot, cast(void*)(&root.proot + 1));
        }

        //scan through all ranges
        foreach (range; collector.ranges)
        {
            collector.mark(range.pbot, range.ptop);
        }

        //pause threads for this?
        thread_suspendAll();
        thread_processGCMarks(&(collector.isMarked));
        thread_resumeAll();

        //get outta here, garbage!
        collector.sweep();

        collector.mutex.lock();
        collector.collecting = false;
        collector.mutex.unlock();

        return null;
    }
