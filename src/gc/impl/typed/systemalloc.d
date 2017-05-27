/**
 * Contains a set of functions for allocating internal structures.
 *
 */

module gc.impl.typed.systemalloc;

import core.internal.spinlock;

import gc.config; //for runtime configuration
import os = gc.os; //os_mem_map, os_mem_unmap

///Identifier for the size of a page in bytes
enum PAGE_SIZE = 4096; //4kb

extern (C)
{
    // Declared as an extern instead of importing core.exception
    // to avoid inlining - see issue 13725.

    /// Raise an error that describes an invalid memory operation.
    void onInvalidMemoryOperationError() @nogc nothrow;
    /// Raise an error that describes the system as being out of memory.
    void onOutOfMemoryErrorNoGC() @nogc nothrow;
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
        //this can happen because of how structs work when they are initialized
        if(start !is null)
            os_mem_unmap(start, chunkSize);
    }
}



/*
 * Information and book keeping about the allocations used by the GC
 */
struct AllocSystem
{
    static
    {
        debug
        {
            //counters for ensuring all mem maps are handled correctly
            uint mem_maps, mem_unmaps;

            uint mem_mappedSize, mem_unmappedSize;
        }


        ///The memory used by the system.
        //initialized to 64kb/1Mb (256 pages) and assumed to not grow
        MemoryChunk systemMemory;

        /// The list of all memory chunks used by the heap.
        MemoryChunk* heapMemory;

        /// The chunk currently used to perform allocations.
        MemoryChunk* currentChunk;

        ///Mutexes used to
        auto smutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);
        auto hmutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);

        void initialize()
        {
             //is this enough?
            //should system memory actually grow?
            AllocSystem.systemMemory = MemoryChunk(10 * PAGE_SIZE);
            AllocSystem.heapMemory = cast(MemoryChunk*) salloc(MemoryChunk.sizeof);
            AllocSystem.heapMemory.__ctor(2 * PAGE_SIZE); //is this enough to start?
            AllocSystem.currentChunk = AllocSystem.heapMemory;
        }

        void finalize()
        {

            while(heapMemory !is null)
            {
                os_mem_unmap(heapMemory.start, heapMemory.chunkSize);
                heapMemory = heapMemory.nextChunk;
            }

            destroy(systemMemory);

            debug
            {
                import core.stdc.stdio;
                printf("There were %d mem_maps and %d mem_unmaps\n",
                        mem_maps, mem_unmaps);

                printf("Heap use at exit: %d\n\n", mem_mappedSize-mem_unmappedSize);
            }
        }
    }



}

void* os_mem_map(size_t nbytes) nothrow
{
    debug
    {
        AllocSystem.mem_maps++;
        AllocSystem.mem_mappedSize += nbytes;
    }

    return os.os_mem_map(nbytes);
}

int os_mem_unmap(void* base, size_t nbytes) nothrow
{
    debug
    {
        AllocSystem.mem_unmaps++;
        AllocSystem.mem_unmappedSize += nbytes;
    }
    return os.os_mem_unmap(base, nbytes);
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
    AllocSystem.smutex.lock();
    scope (exit) AllocSystem.smutex.unlock();

    void* oldOffset = AllocSystem.systemMemory.offset;
    AllocSystem.systemMemory.offset += size;
    debug
    {
        //shouldn't happen, but still check for it in debug during testing
        if (AllocSystem.systemMemory.offset >
            AllocSystem.systemMemory.start + AllocSystem.systemMemory.chunkSize)
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
    AllocSystem.hmutex.lock();
    scope (exit) AllocSystem.hmutex.unlock();

    //check size of allocation? Do something special if allocating a lot?
    //(a big object, a big array, a large amount of memory is reserved?)

    if (AllocSystem.currentChunk.offset + size >
        AllocSystem.currentChunk.start + AllocSystem.currentChunk.chunkSize)
    {
        //or something generated by a growth algorithm?
        size_t newChunkSize = 2 * PAGE_SIZE;
        MemoryChunk* newChunk = cast(MemoryChunk*) salloc(MemoryChunk.sizeof);

        //may throw out of memory error
        newChunk.__ctor(newChunkSize);

        AllocSystem.currentChunk.nextChunk = newChunk;
        AllocSystem.currentChunk = newChunk;

    }

    void* oldOffset = AllocSystem.currentChunk.offset;
    AllocSystem.currentChunk.offset += size;
    return oldOffset;
}


//This function allocates a class using salloc
//it assumes that the constructor handles all initialization
//so that it can avoid copying the initializer
T New(T, Args...)(auto ref Args args) nothrow
if(is(T == class))
{
    import core.stdc.string: memcpy;
    auto ptr = salloc(__traits(classInstanceSize, T));

    //this can be added back if initialization becomes a problem
    auto init = typeid(T).initializer();
    memcpy(ptr, init.ptr, init.length);

    (cast(T)ptr).__ctor(args);
    return cast(T)ptr;
}

//This function allocates a pointer to a struct using salloc

T* New(T, Args...)(auto ref Args args) nothrow
if(is(T == struct))
{
    auto ptr = salloc(T.sizeof);
    static if(Args.length >0)
        (cast(T*)ptr).__ctor(args);

    return cast(T*)ptr;
}
