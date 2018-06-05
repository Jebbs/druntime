//Everything related to memory for the type GC
module gc.impl.type.memory;

import gc.os;
import core.bitop;
import core.internal.spinlock;
import core.stdc.string;

import cstdlib = core.stdc.stdlib : malloc, free;

/// Raise an error that describes the system as being out of memory.
extern(C) void onOutOfMemoryErrorNoGC() @nogc nothrow;

enum PAGE_SIZE = 4096;//4kb
enum CHUNK_SIZE=1024*1024*1024; //Size per GC Chunk (1GB, maybe configurable)
enum BLOCK_SIZE=1024*1024;      //Size given to a Type as requested (1MB, maybe configurable)

shared(int) MAX_GB = 16; //Max size in GB the heap could ever be, should be configurable


/**
 * A structure which is used for interacting with the underlying memory used by
 * the GC.
 *
 * This structure will allow types to request and free blocks of memory, and
 * will ensure that memory is available as needed.
 *
 */
struct GCAllocator
{

    // chekcing something while debugging
    bool initialized = false;

    //allow for a variable number of GB (configurable)
    MemoryChunk* gcMemory;
    uint chunkCount;
    uint currentChunk;
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);


    ~this()
    {
        for(int i = 0; i < chunkCount; ++i)
            destroy(gcMemory[i]);

        cstdlib.free(gcMemory);
    }

    /**
     * Initialize the memory system for the GC.
     *
     * This will reserve a 1GB address range for the program to use, which can
     * if necessary.
     */
    void initialize() nothrow @nogc
    {
        //get memory for the array of chunks
        gcMemory = cast(MemoryChunk*)cstdlib.malloc(MemoryChunk.sizeof * MAX_GB);
        if(gcMemory is null)
            onOutOfMemoryErrorNoGC();

        currentChunk = 0;
        chunkCount = 1;

        initializeChunk(gcMemory[currentChunk]);

        initialized = true;
    }

    /**
     * Returns the address of an unused block (1MB) of memory. This block will
     * be associated with the type that requested it.
     */
    void* allocBlock(int typeID) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();

        auto initi = initialized;

        void* blockAddress = gcMemory[currentChunk].allocBlock(typeID);

        //if this block is out of memory, need to get the next block
        if(!gcMemory[currentChunk].topLevel)
        {
            currentChunk = 0;
            for(;currentChunk< chunkCount; ++currentChunk)
            {
                if(gcMemory[currentChunk].topLevel)
                    break;
            }

            //need to get a new chunk (this shouldn't happen often)
            if(currentChunk > chunkCount)
            {
                chunkCount = currentChunk;
                initializeChunk(gcMemory[currentChunk]);
            }
        }

        return blockAddress;
    }

    /**
     * Free a block for use for another type.
     *
     * If the address is not contained in GC memory, this does nothing.
     */
    void freeBlock(void* blockAddress) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();

        for(int i = 0; i < chunkCount; ++i)
        {
            if(gcMemory[i].chunkStart >= blockAddress &&
               blockAddress < gcMemory[i].chunkStart+CHUNK_SIZE)
            {
                gcMemory[i].freeBlock(blockAddress);
            }
        }
    }

    /**
     * Look up the type associated with this pointer.
     *
     * Returns:
     *  The index of the TypeManager in the Manager array, or -1 if this pointer
     *  references non-GC memory.
     */
    int typeLookup(void* ptr) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();

        auto initi = this.initialized;

        for(int i = 0; i < chunkCount; ++i)
        {
            debug auto start = gcMemory[i].chunkStart;
            debug auto end = gcMemory[i].chunkStart+CHUNK_SIZE;
            if(gcMemory[i].chunkStart <= ptr && ptr < gcMemory[i].chunkStart+CHUNK_SIZE)
            {
                return gcMemory[i].typeLookup(ptr);
            }
        }

        return -1;
    }

    /**
     * Given a chunk, this will initialize the chunk and give it some memory
     * from the OS for it to use.
     */
    void initializeChunk(ref MemoryChunk chunk) nothrow @nogc
    {
        auto init = typeid(MemoryChunk).initializer();
        memcpy(&chunk, init.ptr, init.length);

        void* chunkMemory = os_mem_map(CHUNK_SIZE);
        int* typeMap = cast(int*)os_mem_map(PAGE_SIZE);

        if(chunkMemory is null || typeMap is null)
            onOutOfMemoryErrorNoGC();

        // Assume two's complement because reasons
        // Initialize all typeID's to be unused (-1)
        memset(typeMap, -1, PAGE_SIZE);

        // Provide the memory and map locations to the chunk
        chunk.chunkStart = chunkMemory;
        chunk.typeMap = typeMap;

    }
}

struct MemoryChunk
{
    void* chunkStart;
    ushort topLevel = 0xFFFF;
    ulong[16] freeMap = [0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF];
    int* typeMap;//points to a page
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);

    /**
     * Destructor
     */
    ~this()
    {
        // free all that mems
        os_mem_unmap(typeMap, PAGE_SIZE);
        os_mem_unmap(chunkStart, CHUNK_SIZE);
    }

    void* allocBlock(int typeID) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();

        auto arrPos = bsf(topLevel);
        auto blockOffset = bsf(freeMap[arrPos]);
        auto blockIndex = (arrPos<<5) + blockOffset;

        void* addr = chunkStart + (blockIndex * BLOCK_SIZE);
        freeMap[arrPos] &= ~(1<<blockOffset);

        if (freeMap[arrPos] == 0)
            topLevel&= ~(1<<arrPos);

        typeMap[blockIndex] = typeID;

        return addr;
    }

    void freeBlock(void* blockAddress) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();

        int blockIndex = cast(int)((blockAddress-chunkStart)/BLOCK_SIZE);
        auto arrPos = blockIndex>>6;

        freeMap[arrPos] |= (1L << (blockIndex & 63));
        topLevel |= (1 << (arrPos));
        typeMap[blockIndex] = -1;
    }

    int typeLookup(void* ptr) nothrow @nogc
    {
        //assume ptr is in this chunk

        mutex.lock();
        scope(exit) mutex.unlock();

        auto block = (ptr-chunkStart)/BLOCK_SIZE;

        return typeMap[(ptr-chunkStart)/BLOCK_SIZE];
    }

}

unittest
{
    import core.stdc.stdio;
    //printf("Unittest for memory.d\n");

    GCAllocator mem;
    mem.initialize();

    int typeID = 5;

    void* block = mem.allocBlock(typeID);

    // Confirm we were given a real address
    assert(block !is null);
    assert(mem.gcMemory[mem.currentChunk].topLevel == 0xFFFF);
    assert(mem.gcMemory[mem.currentChunk].freeMap[0] == 0xFFFFFFFFFFFFFFFE);
    assert(typeID == mem.typeLookup(block));


    mem.freeBlock(block);
    assert(mem.gcMemory[mem.currentChunk].freeMap[0] == 0xFFFFFFFFFFFFFFFF);
    assert(-1 == mem.typeLookup(block));
}