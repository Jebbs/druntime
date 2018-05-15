

module gc.impl.type.typemanager;
import gc.impl.type.scan;


import core.internal.spinlock;
static import core.memory;
alias BlkAttr = core.memory.GC.BlkAttr;
alias BlkInfo = core.memory.GC.BlkInfo;

import gc.impl.type.memory;
import gc.os;

import core.bitop;
import cstdlib = core.stdc.string : memcpy, memset;

/// Call the destructor/finalizer on a given object.
extern(C) void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;

//used for slow gorwing arrays (expands one page at a time)
struct Array(T)
{
    void* items;
    size_t itemPadding;
    uint pageCount;
    uint itemCount;

    @property uint capacity() const @nogc
    {
        return pageCount*PAGE_SIZE/(T.sizeof+itemPadding);
    }

    void init(size_t padding = 0) nothrow @nogc
    {
        pageCount = 1;
        items = os_mem_map(PAGE_SIZE);
        itemPadding = padding;
    }

    ~this()
    {
        os_mem_unmap(items, pageCount*PAGE_SIZE);
    }

    int addItem()  nothrow @nogc
    {
        itemCount++;

        //expand by one page if needed
        if(itemCount > capacity)
        {
            pageCount++;
            auto newMem = os_mem_map(pageCount*PAGE_SIZE);
            cstdlib.memcpy(newMem, items, (itemCount-1)*(T.sizeof+itemPadding));
            os_mem_unmap(items, (pageCount-1)*PAGE_SIZE);
            items = newMem;
        }

        return itemCount-1;
    }

    ref T opIndex(size_t index)  nothrow @nogc
    {
        return *(cast(T*)(items+index*(T.sizeof+itemPadding)));
    }

}


//manages the pages in a Block and the buckets they map to
struct BlockManager
{
    void* startAddress;
    ulong[4] freemap = [ulong.max, ulong.max, ulong.max, ulong.max];
    int nextBlock = -1;

    this(void* blockAddress) nothrow @nogc
    {
        startAddress = blockAddress;
    }

    bool contains(void* p) nothrow @nogc
    {
        return (startAddress <= p && p < startAddress+BLOCK_SIZE);
    }

    bool isFull() nothrow @nogc
    {
        foreach(section; freemap)
        {
            if(section)
                return false;
        }

        return true;
    }

    //returns the position of the page and marks is as used
    int allocPage() nothrow @nogc
    {
        for(int offset = 0; offset < freemap.length; offset++)
        {
            if(freemap[offset] > 0)
            {
                auto pos = bsf(freemap[offset]);

                freemap[offset] &= ~(1 << pos);

                return offset*64 + pos;//64 bits in a ulong
            }
        }

        return -1;
    }

    int allocPages(int pageCount) nothrow @nogc
    {
        for(int offset = 0; offset < freemap.length; offset++)
        {
            if(freemap[offset] > 0)
            {
                auto pos = gsf(freemap[offset], pageCount);
                if(pos < 0)
                    continue;

                for(int i = 0; i < pageCount; ++i)
                    freemap[offset] &= ~(1 << (pos+i));

                return offset*64 + pos;//64 bits in a ulong
            }
        }

        return -1;
    }

    void freePage(int page) nothrow @nogc
    {
        //64 bits in a ulong
        int set = page/64;
        int pos = page%64;

        freemap[set] |= (1 << pos);
    }

    void freePages(int pageStart, int pageCount) nothrow @nogc
    {
        //64 bits in a ulong
        int set = pageStart/64;
        int pos = pageStart%64;

        for(int i = 0; i < pageCount; ++i)
        {
            freemap[set] |= (1 << pos+i);
        }
    }

    void* pageAddress(int page) nothrow @nogc
    {
        return startAddress + page*PAGE_SIZE;
    }


    int pageIndex(void* pageAddr) nothrow @nogc
    {
        //lookup page or something
        return -1;
    }
    //scans for the first set of contiguous bits (groups scan forward)
    int gsf(ulong input, int groupSize) nothrow @nogc
    {
        auto bits = input;
        for(int i = 1; i < groupSize; i++)
            bits&=(input>>i);

        return bits?bsf(bits):-1;
    }
}

//The base class for type managers
class TypeManager
{
    //reference to memory allocator
    //static shared(GCAllocator)* allocator;

    static GCAllocator* allocator;

    const TypeInfo info; //type info reference for hash comparison
    size_t* pointerMap; //a bitmap representing the layout of pointers
    size_t objectSize; //the size of individual objects
    int hashIndex;
    bool shouldCollect;
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);

    this(const TypeInfo ti, int index) nothrow @nogc
    {
        info = ti;
        hashIndex = index;
    }

    final void* alloc(size_t size, ubyte bits) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _alloc(size, bits);
    }

    final BlkInfo qalloc(size_t size, ubyte bits) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _qalloc(size, bits);
    }

    final void* realloc(void* p, size_t size, ubyte bits) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _realloc(p, size, bits);
    }

    final void free(void* p) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        _free(p);
    }

    final uint getAttr(void* p) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _getAttr(p);
    }

    final uint setAttr(void* p, ubyte mask) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _setAttr(p, mask);
    }

    final uint clrAttr(void* p, ubyte mask) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _clrAttr(p, mask);
    }

    final void* addrOf(void* p) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _addrOf(p);
    }

    final size_t sizeOf(void* p) nothrow @nogc
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _sizeOf(p);
    }

    final BlkInfo query(void* p)  nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _query(p);
    }

    final void sweep() nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _sweep();
    }

    final void prepare() nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _prepare();
    }

    final bool testMarkAndSet(void* p) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _testMarkAndSet(p);
    }

    final void scan(ref ScanStack scanStack, void* ptr) nothrow
    {
        if(pointerMap == rtinfoNoPointers)
            return;

        mutex.lock();
        scope(exit) mutex.unlock();
        return _scan(scanStack, ptr);
    }

    final bool isMarked(void* p) nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return _isMarked(p);
    }
    final bool requiresCollection() nothrow
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        bool ret = shouldCollect;
        shouldCollect = false;
        return ret;
    }

    abstract void* _alloc(size_t size, ubyte bits) nothrow;

    abstract BlkInfo _qalloc(size_t size, ubyte bits) nothrow;

    abstract void* _realloc(void* p, size_t size, ubyte bits) nothrow;

    abstract void _free(void* p) nothrow;

    abstract uint _getAttr(void* p) nothrow @nogc;

    abstract uint _setAttr(void* p, ubyte mask) nothrow @nogc;

    abstract uint _clrAttr(void* p, ubyte mask) nothrow @nogc;

    abstract void* _addrOf(void* p) nothrow @nogc;

    abstract size_t _sizeOf(void* p) nothrow @nogc;

    abstract BlkInfo _query(void* p)  nothrow;

    abstract void _sweep() nothrow;

    abstract void _prepare() nothrow;

    abstract bool _testMarkAndSet(void* p) nothrow;

    abstract void _scan(ref ScanStack scanStack, void* ptr) nothrow;

    abstract bool _isMarked(void* p) nothrow;
}

class RawManager: TypeManager
{
    static size_t[5] blockSizes = [128, 256, 512, 1024, 2048];

    //buckets used for raw memory allocations
    struct Bucket
    {
        //this makes it less variable and all buckets can be in one place
        ubyte[32] attributes; //uses extra memory, but makes things easier
        uint freeMap;
        uint markMap;
        void* memory;
        size_t blockSize;
        int nextBucketID = -1;
        int index = -1;//keep the index here

        this(void* mem, size_t bSize, int i) nothrow @nogc
        {
            memory = mem;
            blockSize = bSize;
            index = i;

            //set the freemap to be based on the size
            if(blockSize == 128)
                freeMap = uint.max;
            else if(blockSize == 256)
                freeMap = 0b1111111111111111;
            else if(blockSize == 512)
                freeMap = 0b11111111;
            else if(blockSize == 1024)
                freeMap = 0b1111;
            else if(blockSize == 2048)
                freeMap = 0b11;
            else
                freeMap = 1;

            markMap = ~freeMap;
        }

        void* alloc(ubyte bits) nothrow
        {
            auto pos = bsf(freeMap);

            //set the attributes, remove the free slot, and mark it as found
            attributes[pos] = bits;
            freeMap &= ~(1 << pos);
            markMap |= (1 << pos);

            void* actualLocation = memory + pos * blockSize;

            return actualLocation;
        }

        void* realloc(void* p, ubyte attr) nothrow
        {
            auto pos = (p - memory) / blockSize;

            //if this pointer is currently an object, just reset the attribute
            if((~freeMap) & (1 << pos))
            {
                attributes[pos] = attr;
                return p;
            }

            //otherwise, allocate some space for it
            return alloc(attr);
        }

        uint getAttr(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
                return attributes[pos];

            return 0;
        }

        uint setAttr(void* p, ubyte mask) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                attributes[pos] |= mask;
                return attributes[pos];
            }

            return 0;
        }

        uint clrAttr(void* p, ubyte mask) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                //the compiler sure is dumb
                attributes[pos] &= cast(ubyte)(~cast(int)mask);
                return attributes[pos];
            }

            return 0;
        }

        void* addrOf(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                return memory + pos * blockSize;
            }

            return null;
        }

        size_t sizeOf(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                return blockSize;
            }

            return 0;
        }

        BlkInfo query(void* p) nothrow @nogc
        {
            BlkInfo ret;

            auto pos = (p - memory) / blockSize;

            if(~freeMap & (1 << pos))
            {
                ret.base = memory + pos * blockSize;
                ret.size = blockSize;
                ret.attr = attributes[pos];
            }

            return ret;
        }

        void free(void* p) nothrow
        {
            auto pos = (p - memory) / blockSize;

            if((~freeMap) & (1 << pos))
                freeMap |= (1 << pos);
        }

        void prepare() nothrow @nogc
        {
            //potentially set some spots as "found" so that the sweep logic is simpler
            if(blockSize == 128)
                markMap = 0;
            else if(blockSize == 256)
                markMap = ~cast(uint)ushort.max;
            else if(blockSize == 512)
                markMap = ~cast(uint)ubyte.max;
            else if(blockSize == 1024)
                markMap = ~cast(uint)0b1111;
            else if(blockSize == 2048)
                markMap = ~cast(uint)0b11;
            else
                markMap = ~cast(uint)1;
        }

        void sweep() nothrow
        {
            auto toFree = markMap ^ ~freeMap;

            // for each block not marked, free it
            while (toFree)
            {
                auto pos = bsf(toFree);

                freeMap |= (1 << pos);

                toFree &= ~(1<<pos);
            }
        }

        bool testMarkAndSet(void* ptr) nothrow @nogc
        {
            auto pos = (ptr - memory) / blockSize;
            uint markBit = 1 << pos;

            if (markMap & markBit)
                return true;

            markMap |= markBit;
            return false;
        }

        bool isMarked(void* ptr) nothrow @nogc
        {
            auto pos = (ptr - memory) / blockSize;
            uint markBit = 1 << pos;

            if((~freeMap) & (1 << pos))
                return (markMap & markBit) ? true : false;

            return false;
        }

        void scan(ref ScanStack scanStack, void* ptr, size_t* pointerMap) nothrow
        {
            scanStack.push(ScanRange(memory, memory + blockSize, pointerMap));
        }

        bool isEmpty() nothrow
        {
            if(blockSize == 128)
                return (freeMap == uint.max);
            else if(blockSize == 256)
                return (freeMap == 0b1111111111111111);
            else if(blockSize == 512)
                return (freeMap == 0b11111111);
            else if(blockSize == 1024)
                return (freeMap == 0b1111);
            else if(blockSize == 2048)
                return (freeMap == 0b11);
            else
                return (freeMap == 1);
        }
    }

    Array!(Bucket) buckets;
    Array!(BlockManager) blocks;
    Array!(int[256]) bucketMap;

    int currentBlock;

    //the buckets to perform allocations from based on size
    int[5] sizeBuckets = [-1,-1,-1,-1,-1];

    //free list of buckets for when a bucket isn't needed anymore
    int freeList = -1;

    this(uint index) nothrow @nogc
    {
        super(null, index);

        //everything is a pointer!
        pointerMap = cast(size_t*)1;

        buckets.init();
        blocks.init();
        bucketMap.init();
        addBlock();
    }

    int addBucket(size_t size) nothrow @nogc
    {
         int bucketIndex;
         if(freeList != -1)
         {
            bucketIndex = freeList;
            freeList = buckets[bucketIndex].nextBucketID;
         }
         else
         {
            bucketIndex = buckets.addItem();
         }
         auto pageIndex = blocks[currentBlock].allocPage();
         buckets[bucketIndex] = Bucket(blocks[currentBlock].pageAddress(pageIndex),
                                        size, bucketIndex);

        bucketMap[currentBlock][pageIndex] = bucketIndex;

         return bucketIndex;
    }

    void addBlock() nothrow @nogc
    {
        //get a new block
        auto blockIndex = blocks.addItem();
        blocks[blockIndex] = BlockManager(allocator.allocBlock(hashIndex));

        //get a new map
        bucketMap.addItem();
        cstdlib.memset(bucketMap[blockIndex].ptr, -1, bucketMap[blockIndex].length*int.sizeof);

        //set it as the current block we're using for allocations
        currentBlock = blockIndex;
    }

    override void* _alloc(size_t size, ubyte bits) nothrow
    {
        size_t dummy;
        return (size > PAGE_SIZE/2)?bigAllocImpl(size, bits, dummy):
                                    allocImpl(size, bits, dummy);
    }

    void* allocImpl(size_t size, ubyte bits, out size_t blockSize) nothrow
    {
        int sizeIndex = getSizeClass(size);

        auto bucketIndex = sizeBuckets[sizeIndex];
        blockSize = blockSizes[sizeIndex];
        if(bucketIndex >= 0)
        {
            auto allocatedMemory = buckets[bucketIndex].alloc(bits);

            //if the bucket became full, have another ready for next allocation
            if(buckets[bucketIndex].freeMap == 0)
            {
                if(buckets[bucketIndex].nextBucketID < 0)
                {
                    //instead of making a new bucket for allocation right away
                    //we should tell the collector to make a collection
                    shouldCollect = true;

                    /*
                    auto nextBucket = addBucket(blockSizes[sizeIndex]);
                    sizeBuckets[sizeIndex] = nextBucket;
                    */
                }
                else
                {
                    sizeBuckets[sizeIndex] = buckets[bucketIndex].nextBucketID;
                }
            }

            return allocatedMemory;
        }

        //create a new bucket and allocate from it
        bucketIndex = addBucket(blockSizes[sizeIndex]);
        sizeBuckets[sizeIndex] = bucketIndex;
        return buckets[bucketIndex].alloc(bits);

    }

    void* bigAllocImpl(size_t size, ubyte bits, out size_t blockSize) nothrow
    {
        //let's go ahead and just say we want to make a collection because this
        //uses one or more pages
        shouldCollect = true;

        int pageCount = 1;
        for(; pageCount*PAGE_SIZE < size; ++pageCount){}

        if(pageCount == 1)
        {
            blockSize = PAGE_SIZE;
            auto bucketIndex = addBucket(PAGE_SIZE);
            return buckets[bucketIndex].alloc(bits);
        }

        blockSize = pageCount*PAGE_SIZE;
        int bucketIndex;
        if(freeList != -1)
        {
        bucketIndex = freeList;
        freeList = buckets[bucketIndex].nextBucketID;
        }
        else
        {
        bucketIndex = buckets.addItem();
        }

        auto pageIndex = blocks[currentBlock].allocPages(pageCount);
        buckets[bucketIndex] = Bucket(blocks[currentBlock].pageAddress(pageIndex),
                                        blockSize, bucketIndex);
        for(int i = 0; i < pageCount; ++i)
            bucketMap[currentBlock][pageIndex+i] = bucketIndex;

        return buckets[bucketIndex].alloc(bits);
    }

    override BlkInfo _qalloc(size_t size, ubyte bits) nothrow
    {
        BlkInfo ret;

        ret.base = (size > PAGE_SIZE/2)?bigAllocImpl(size, bits, ret.size):
                                        allocImpl(size, bits, ret.size);
        ret.attr = bits;

        return ret;
    }

    override void* _realloc(void* p, size_t size, ubyte bits) nothrow
    {
        import core.stdc.string : memcpy;

        auto bucket = findBucket(p);

        if(size == 0)
        {
            bucket.free(p);
            return null;
        }

        //if the size still fits, keep using it
        if(size <= bucket.blockSize)
        {
            //checks for existance
            return bucket.realloc(p,bits);
        }

        //otherwise perform a new allocation and copy the memory
        void* newPtr = _alloc(size, bits);
        return memcpy(newPtr, p, bucket.blockSize);
    }

    override void _free(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.free(p);
    }

    override uint _getAttr(void* p) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.getAttr(p);

        return 0;
    }

    override uint _setAttr(void* p, ubyte mask) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.setAttr(p, mask);

        return 0;
    }

    override uint _clrAttr(void* p, ubyte mask) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.clrAttr(p, mask);

        return 0;
    }

    override void* _addrOf(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.addrOf(p);

        return null;
    }

    override size_t _sizeOf(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.sizeOf(p);

        return 0;
    }

    override BlkInfo _query(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.query(p);

        return BlkInfo.init;
    }

    override void _sweep() nothrow
    {
        auto count = buckets.itemCount;

        for(int i = 0; i < count; ++i)
        {
            auto bucket = &buckets[i];
            bucket.sweep();

            if(bucket.isEmpty())
            {

                int breaker = 0;
                //free memory
                void* pageStart = bucket.memory;
                auto pageCount = bucket.blockSize/PAGE_SIZE + (bucket.blockSize%PAGE_SIZE)?1:0;
                auto block = findBlock(pageStart);
                int pageNumber = cast(int)((pageStart-block.startAddress)/PAGE_SIZE);
                block.freePages(pageNumber, pageCount);

                //add to free list
                bucket.nextBucketID = freeList;
                freeList = i;
            }
            else if(bucket.freeMap)//has a mixture of free and empty spots
            {
                int sizeIndex = getSizeClass(bucket.blockSize);
                auto bucketIndex = sizeBuckets[sizeIndex];

                //set this buckt to be the next one we allocate from (if not already)
                if(i != bucketIndex)
                {
                    bucket.nextBucketID = bucketIndex;
                    sizeBuckets[sizeIndex] = i;
                }
            }
        }
    }

    override void _prepare() nothrow
    {
        auto count = buckets.itemCount;

        for(int i = 0; i < count; ++i)
        {
            buckets[i].prepare();
        }
    }

    override bool _testMarkAndSet(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.testMarkAndSet(p);

        return false;
    }

    override void _scan(ref ScanStack scanStack, void* ptr) nothrow
    {
        auto bucket = findBucket(ptr);

        if(bucket)
            bucket.scan(scanStack, ptr, pointerMap);
    }

    override bool _isMarked(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.isMarked(p);

        return false;
    }

    Bucket* findBucket(void* p) nothrow @nogc
    {
        auto cap = blocks.itemCount;

        int blockIndex;
        int pageIndex;
        for(int i = 0; i < cap; ++i)
        {
            if(blocks[i].contains(p))
            {
                blockIndex = i;
                break;
            }
        }

        auto pageNumber = (p-blocks[blockIndex].startAddress)/PAGE_SIZE;
        auto bucketIndex = bucketMap[blockIndex][pageNumber];

        return &buckets[bucketIndex];
    }

    BlockManager* findBlock(void* p) nothrow @nogc
    {
        auto cap = blocks.itemCount;

        int blockIndex;
        int pageIndex;
        for(int i = 0; i < cap; ++i)
        {
            if(blocks[i].contains(p))
            {
                blockIndex = i;
                break;
            }
        }

        return &blocks[blockIndex];
    }

    int getSizeClass(size_t size) nothrow @nogc
    {
        if(size <= 128)
            return 0;
        else if(size <= 256)
            return 1;
        else if(size <= 512)
            return 2;
        else if(size <= 1024)
            return 3;
        else
            return 4;
    }
}

unittest
{
    import gc.impl.type.typehash;

    GCAllocator allocator;
    allocator.initialize();
    TypeManager.allocator = &allocator;

    TypeHash typeHash;
    typeHash.initialize();

    size_t allocationSize = 128;

    //request the manager for an allocation size with no type information
    auto rawManager = typeHash.getTypeManager(allocationSize, null);

    assert(cast(RawManager)rawManager !is null, "The returned manager was not a RawManager.");

    ubyte bits = 0b1011;

    //allocate for the first time
    void* p = rawManager.alloc(32, bits);

    assert(allocationSize == rawManager.sizeOf(p));

    BlkInfo info = {p, allocationSize, bits};

    assert(info == rawManager.query(p), "Didn't get the correct info about allocation.");


    rawManager.free(p);
    assert(0 == rawManager.sizeOf(p));

    //allocate multiple times in a row;

    void* p1 = rawManager.alloc(32, bits);
    void* p2 = rawManager.alloc(32, bits);

    assert(allocationSize == rawManager.sizeOf(p1));
    assert(allocationSize == rawManager.sizeOf(p2));

    info = BlkInfo(p1, allocationSize, bits);
    assert(info == rawManager.query(p1), "Didn't get the correct info about allocation.");
    info = BlkInfo(p2, allocationSize, bits);
    assert(info == rawManager.query(p2), "Didn't get the correct info about allocation.");


    rawManager.free(p1);
    rawManager.free(p2);
    assert(0 == rawManager.sizeOf(p1));
    assert(0 == rawManager.sizeOf(p2));



    //more tests (each size)
    auto bigSize = PAGE_SIZE/2;
    auto p3 = rawManager.alloc(bigSize, bits);
    auto p4 = rawManager.alloc(bigSize, bits);
    auto p5 = rawManager.alloc(bigSize, bits);

    assert(bigSize == rawManager.sizeOf(p3));
    assert(bigSize == rawManager.sizeOf(p4));
    assert(bigSize == rawManager.sizeOf(p5));

    rawManager.free(p3);
    rawManager.free(p4);
    rawManager.free(p5);



    auto hugeSize = PAGE_SIZE+bigSize;
    auto p6 = rawManager.alloc(hugeSize, bits);

    assert(PAGE_SIZE*2 == rawManager.sizeOf(p6));

    rawManager.free(p6);

    //additional coverage tests
    auto p7 = rawManager.alloc(32, bits);

    auto p8 = rawManager.realloc(p7, 64, bits);

    assert(p7 == p8, "Reallocation created a new pointer, but it shouldn't have");

    auto p9 = rawManager.realloc(p7, 64*3, bits);

    assert(p7 != p9, "Reallocation should have created a new pointer, but it didn't");

    assert(cast(uint)bits == rawManager.getAttr(p7), "Get bits aren't the same!");

    assert(0b1111 == rawManager.setAttr(p7, 0b0100), "Set bits aren't the same!");

    assert(0b1010 == rawManager.clrAttr(p7, 0b0101), "Clear bits aren't the same!");

    assert(p7 == rawManager.addrOf(p7), "Addresses aren't the same!");
    assert(p7 == rawManager.addrOf(p7+50), "Addresses aren't the same!");

    rawManager.free(p7);
    rawManager.free(p9);
}

class ArrayManager: TypeManager
{
    static size_t[5] blockSizes = [128, 256, 512, 1024, 2048];

    //buckets used for array memory allocations
    struct Bucket
    {
        //this makes it less variable and all buckets can be in one place
        ubyte[32] attributes; //uses extra memory, but makes things easier
        uint freeMap;
        uint markMap;
        void* memory;
        size_t blockSize;
        int nextBucketID = -1;
        int index = -1;//keep the index here

        this(void* mem, size_t bSize, int i) nothrow @nogc
        {
            memory = mem;
            blockSize = bSize;
            index = i;

            //set the freemap to be based on the size
            if(blockSize == 128)
                freeMap = uint.max;
            else if(blockSize == 256)
                freeMap = 0b1111111111111111;
            else if(blockSize == 512)
                freeMap = 0b11111111;
            else if(blockSize == 1024)
                freeMap = 0b1111;
            else if(blockSize == 2048)
                freeMap = 0b11;
            else
                freeMap = 1;
        }

        void* alloc(ubyte bits) nothrow
        {
            auto pos = bsf(freeMap);

            //set the attributes, remove the free slot, and mark it as found
            attributes[pos] = bits;
            freeMap &= ~(1 << pos);
            markMap |= (1 << pos);

            void* actualLocation = memory + pos * blockSize;

            return actualLocation;
        }

        void* realloc(void* p, ubyte attr) nothrow
        {
            auto pos = (p - memory) / blockSize;

            //if this pointer is currently an object, just reset the attribute
            if((~freeMap) & (1 << pos))
            {
                attributes[pos] = attr;
                return p;
            }

            //otherwise, allocate some space for it
            return alloc(attr);

        }

        uint getAttr(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
                return attributes[pos];

            return 0;
        }

        uint setAttr(void* p, ubyte mask) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                attributes[pos] |= mask;
                return attributes[pos];
            }

            return 0;
        }

        uint clrAttr(void* p, ubyte mask) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                //the compiler sure is dumb
                attributes[pos] &= cast(ubyte)(~cast(int)mask);
                return attributes[pos];
            }

            return 0;
        }

        void* addrOf(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                return memory + pos * blockSize;
            }

            return null;
        }

        size_t sizeOf(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / blockSize;
            if((~freeMap) & (1 << pos))
            {
                return blockSize;
            }

            return 0;
        }

        BlkInfo query(void* p) nothrow @nogc
        {
            BlkInfo ret;

            auto pos = (p - memory) / blockSize;

            if(~freeMap & (1 << pos))
            {
                ret.base = memory + pos * blockSize;
                ret.size = blockSize;
                ret.attr = attributes[pos];
            }

            return ret;
        }

        void free(void* p) nothrow
        {
            auto pos = (p - memory) / blockSize;

            if((~freeMap) & (1 << pos))
                freeMap |= (1 << pos);
        }

        void sweep() nothrow
        {
            auto toFree = markMap ^ ~freeMap;

            // for each block not marked, free it
            while (toFree)
            {
                auto pos = bsf(toFree);

                freeMap |= (1 << pos);

                if (attributes[pos] & BlkAttr.FINALIZE || attributes[pos] & BlkAttr.STRUCTFINAL)
                {
                    rt_finalizeFromGC(memory + pos * blockSize, blockSize, attributes[pos]);
                }

                toFree &= ~(1<<pos);
            }
        }

        void prepare() nothrow @nogc
        {
            //potentially set some spots as "found" so that the sweep logic is simpler
            if(blockSize == 128)
                markMap = 0;
            else if(blockSize == 256)
                markMap = ~cast(uint)ushort.max;
            else if(blockSize == 512)
                markMap = ~cast(uint)ubyte.max;
            else if(blockSize == 1024)
                markMap = ~cast(uint)0b1111;
            else if(blockSize == 2048)
                markMap = ~cast(uint)0b11;
            else
                markMap = ~cast(uint)1;
        }

        bool testMarkAndSet(void* ptr) nothrow @nogc
        {
            auto pos = (ptr - memory) / blockSize;
            uint markBit = 1 << pos;

            if (markMap & markBit)
                return true;

            markMap |= markBit;
            return false;
        }

        bool isMarked(void* ptr) nothrow @nogc
        {
            auto pos = (ptr - memory) / blockSize;
            uint markBit = 1 << pos;

            if((~freeMap) & (1 << pos))
                return (markMap & markBit) ? true : false;

            return false;
        }

        void scan(ref ScanStack scanStack, void* ptr, size_t* pointerMap) nothrow
        {
            scanStack.push(ScanRange(memory, memory + blockSize, pointerMap));
        }

        bool isEmpty() nothrow
        {
            if(blockSize == 128)
                return (freeMap == uint.max);
            else if(blockSize == 256)
                return (freeMap == 0b1111111111111111);
            else if(blockSize == 512)
                return (freeMap == 0b11111111);
            else if(blockSize == 1024)
                return (freeMap == 0b1111);
            else if(blockSize == 2048)
                return (freeMap == 0b11);
            else
                return (freeMap == 1);
        }
    }

    Array!(Bucket) buckets;
    Array!(BlockManager) blocks;
    Array!(int[256]) bucketMap;

    int currentBlock;

    //the buckets to perform allocations from based on size
    int[5] sizeBuckets = [-1,-1,-1,-1,-1];

    //free list of buckets for when a bucket isn't needed anymore
    int freeList;

    this(const TypeInfo ti, int index) nothrow @nogc
    {
        //need this in order to correctly initialize the type info
        super(ti, index);

        auto pointerType = ((cast(const TypeInfo_Pointer) ti.next !is null) ||
                   (cast(const TypeInfo_Class) ti.next !is null));

        if(pointerType)
        {
            //if the type is a pointer or reference type, we will always
            //have one indirection to the actual object, which is stored in its
            //own bucket
            objectSize = size_t.sizeof;
            pointerMap = cast(size_t*)rtinfoHasPointers;
        }
        else
        {
            auto tinext = ti.next;

            auto sz = tinext.tsize;
            auto rtInfo = cast(size_t*) ti.next.rtInfo();
            if (rtInfo is rtinfoHasPointers)
            {
                //not sure what's going on here, but we need to scan conservatively.
                objectSize = tinext.tsize;
                pointerMap = cast(size_t*)rtinfoHasPointers;
            }
            else if (rtInfo !is null)
            {
                //get the actual size from the run time info and copy the address of the pointer map
                objectSize = rtInfo[0];
                pointerMap = rtInfo;
            }
            else
            {
                //otherwise we have something that doesn't need to be scanned
                //(it contains no pointers)
                objectSize = tinext.tsize;
                pointerMap = cast(size_t*)rtinfoNoPointers;
            }
        }

        buckets.init();
        blocks.init();
        bucketMap.init();
        addBlock();
    }

    ~this()
    {
        _prepare();
        _sweep();
    }

    int addBucket(size_t size) nothrow @nogc
    {
         auto bucketIndex = buckets.addItem();
         auto pageIndex = blocks[currentBlock].allocPage();
         buckets[bucketIndex] = Bucket(blocks[currentBlock].pageAddress(pageIndex),
                                        size, bucketIndex);

        bucketMap[currentBlock][pageIndex] = bucketIndex;

         return bucketIndex;
    }

    void addBlock() nothrow @nogc
    {
        //get a new block
        auto blockIndex = blocks.addItem();
        blocks[blockIndex] = BlockManager(allocator.allocBlock(hashIndex));

        //get a new map
        bucketMap.addItem();
        cstdlib.memset(bucketMap[blockIndex].ptr, -1, bucketMap[blockIndex].length*int.sizeof);

        //set it as the current block we're using for allocations
        currentBlock = blockIndex;
    }

    override void* _alloc(size_t size, ubyte bits) nothrow
    {
        size_t dummy;
        return (size > PAGE_SIZE/2)?bigAllocImpl(size, bits, dummy):
                                    allocImpl(size, bits, dummy);
    }

    void* allocImpl(size_t size, ubyte bits, out size_t blockSize) nothrow
    {
        int sizeIndex;

        if(size <= 128)
            sizeIndex = 0;
        else if(size <= 256)
            sizeIndex = 1;
        else if(size <= 512)
            sizeIndex = 2;
        else if(size <= 1024)
            sizeIndex = 3;
        else
            sizeIndex = 4;


        auto bucketIndex = sizeBuckets[sizeIndex];
        blockSize = blockSizes[sizeIndex];
        if(bucketIndex >= 0)
        {
            auto allocatedMemory = buckets[bucketIndex].alloc(bits);

            //if the bucket became full, have another ready for next allocation
            if(buckets[bucketIndex].freeMap == 0)
            {
                if(buckets[bucketIndex].nextBucketID < 0)
                {
                    //instead of making a new bucket for allocation right away
                    //we should tell the collector to make a collection
                    shouldCollect = true;

                    /*
                    auto nextBucket = addBucket(blockSizes[sizeIndex]);
                    sizeBuckets[sizeIndex] = nextBucket;
                    */
                }
                else
                {
                    sizeBuckets[sizeIndex] = buckets[bucketIndex].nextBucketID;
                }
            }
            return allocatedMemory;
        }


        //create a new bucket and allocate from it
        bucketIndex = addBucket(blockSizes[sizeIndex]);
        sizeBuckets[sizeIndex] = bucketIndex;
        return buckets[bucketIndex].alloc(bits);

    }

    void* bigAllocImpl(size_t size, ubyte bits, out size_t blockSize) nothrow
    {
        //let's go ahead and just say we want to make a collection because this
        //uses one or more pages
        shouldCollect = true;

        int pageCount = 1;
        for(; pageCount*PAGE_SIZE < size; ++pageCount){}

        if(pageCount == 1)
        {
            blockSize = PAGE_SIZE;
            auto bucketIndex = addBucket(PAGE_SIZE);
            return buckets[bucketIndex].alloc(bits);
        }


        blockSize = pageCount*PAGE_SIZE;
        auto bucketIndex = buckets.addItem();

        auto pageIndex = blocks[currentBlock].allocPages(pageCount);
        buckets[bucketIndex] = Bucket(blocks[currentBlock].pageAddress(pageIndex),
                                        blockSize, bucketIndex);
        for(int i = 0; i < pageCount; ++i)
            bucketMap[currentBlock][pageIndex+i] = bucketIndex;

        return buckets[bucketIndex].alloc(bits);
    }

    override BlkInfo _qalloc(size_t size, ubyte bits) nothrow
    {
        BlkInfo ret;

        ret.base = (size > PAGE_SIZE/2)?bigAllocImpl(size, bits, ret.size):
                                        allocImpl(size, bits, ret.size);

        ret.attr = bits;

        return ret;
    }

    override void* _realloc(void* p, size_t size, ubyte bits) nothrow
    {
        import core.stdc.string : memcpy;

        auto bucket = findBucket(p);

        if(size == 0)
        {
            bucket.free(p);
            return null;
        }

        //if the size still fits, keep using it
        if(size <= bucket.blockSize)
        {
            //checks for existance
            return bucket.realloc(p,bits);
        }

        //otherwise perform a new allocation and copy the memory
        void* newPtr = _alloc(size, bits);
        return memcpy(newPtr, p, bucket.blockSize);
    }

    override void _free(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            bucket.free(p);
    }

    override uint _getAttr(void* p) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.getAttr(p);

        return 0;
    }

    override uint _setAttr(void* p, ubyte mask) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.setAttr(p, mask);

        return 0;
    }

    override uint _clrAttr(void* p, ubyte mask) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.clrAttr(p, mask);

        return 0;
    }

    override void* _addrOf(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.addrOf(p);

        return null;
    }

    override size_t _sizeOf(void* p) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.sizeOf(p);

        return 0;
    }

    override BlkInfo _query(void* p) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.query(p);

        return BlkInfo.init;
    }

    override void _sweep() nothrow
    {
        auto count = buckets.itemCount;

        for(int i = 0; i < count; ++i)
        {
            auto bucket = &buckets[i];
            bucket.sweep();

            if(bucket.isEmpty())
            {
                //free memory
                void* pageStart = bucket.memory;
                auto pageCount = bucket.blockSize/PAGE_SIZE + (bucket.blockSize%PAGE_SIZE)?1:0;
                auto block = findBlock(pageStart);
                int pageNumber = cast(int)((pageStart-block.startAddress)/PAGE_SIZE);
                block.freePages(pageNumber, pageCount);

                //add to free list
                bucket.nextBucketID = freeList;
                freeList = i;
            }
            else if(bucket.freeMap)//has a mixture of free and empty spots
            {
                int sizeIndex = getSizeClass(bucket.blockSize);
                auto bucketIndex = sizeBuckets[sizeIndex];

                //set this buckt to be the next one we allocate from (if not already)
                if(i != bucketIndex)
                {
                    bucket.nextBucketID = bucketIndex;
                    sizeBuckets[sizeIndex] = i;
                }
            }
        }

    }

    override void _prepare() nothrow
    {
        auto count = buckets.itemCount;

        for(int i = 0; i < count; ++i)
        {
            buckets[i].prepare;
        }
    }

    override bool _testMarkAndSet(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.testMarkAndSet(p);

        return false;
    }

    override void _scan(ref ScanStack scanStack, void* ptr) nothrow
    {
        auto bucket = findBucket(ptr);

        if(bucket)
            bucket.scan(scanStack, ptr, pointerMap);
    }

    override bool _isMarked(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.isMarked(p);

        return false;
    }

    Bucket* findBucket(void* p) nothrow @nogc
    {
        auto cap = blocks.capacity;

        int blockIndex;
        int pageIndex;
        for(int i = 0; i < cap; ++i)
        {
            if(blocks[i].contains(p))
            {
                blockIndex = i;
                break;
            }
        }

        auto pageNumber = (p-blocks[blockIndex].startAddress)/PAGE_SIZE;
        auto bucketIndex = bucketMap[blockIndex][pageNumber];

        return &buckets[bucketIndex];
    }

    BlockManager* findBlock(void* p) nothrow @nogc
    {
        auto cap = blocks.itemCount;

        int blockIndex;
        int pageIndex;
        for(int i = 0; i < cap; ++i)
        {
            if(blocks[i].contains(p))
            {
                blockIndex = i;
                break;
            }
        }

        return &blocks[blockIndex];
    }

    int getSizeClass(size_t size) nothrow @nogc
    {
        if(size <= 128)
            return 0;
        else if(size <= 256)
            return 1;
        else if(size <= 512)
            return 2;
        else if(size <= 1024)
            return 3;
        else
            return 4;
    }
}

unittest
{
    import gc.impl.type.typehash;

    GCAllocator allocator;
    allocator.initialize();
    TypeManager.allocator = &allocator;

    TypeHash typeHash;
    typeHash.initialize();

    size_t allocationSize = 128;

    //request the manager for an allocation size with no type information
    auto arrayManager = typeHash.getTypeManager(allocationSize, typeid(string));

    assert(cast(ArrayManager)arrayManager !is null, "The returned manager was not an ArrayManager.");

    ubyte bits = 0b1011;

    //allocate for the first time
    void* p = arrayManager.alloc(32, bits);

    assert(allocationSize == arrayManager.sizeOf(p));

    BlkInfo info = {p, allocationSize, bits};

    assert(info == arrayManager.query(p), "Didn't get the correct info about allocation.");


    arrayManager.free(p);
    assert(0 == arrayManager.sizeOf(p));

    //allocate multiple times in a row;

    void* p1 = arrayManager.alloc(32, bits);
    void* p2 = arrayManager.alloc(32, bits);

    assert(allocationSize == arrayManager.sizeOf(p1));
    assert(allocationSize == arrayManager.sizeOf(p2));

    info = BlkInfo(p1, allocationSize, bits);
    assert(info == arrayManager.query(p1), "Didn't get the correct info about allocation.");
    info = BlkInfo(p2, allocationSize, bits);
    assert(info == arrayManager.query(p2), "Didn't get the correct info about allocation.");


    arrayManager.free(p1);
    arrayManager.free(p2);
    assert(0 == arrayManager.sizeOf(p1));
    assert(0 == arrayManager.sizeOf(p2));



    //more tests (each size)

    auto bigSize = PAGE_SIZE/2;
    auto p3 = arrayManager.alloc(bigSize, bits);
    auto p4 = arrayManager.alloc(bigSize, bits);
    auto p5 = arrayManager.alloc(bigSize, bits);

    assert(bigSize == arrayManager.sizeOf(p3));
    assert(bigSize == arrayManager.sizeOf(p4));
    assert(bigSize == arrayManager.sizeOf(p5));

    arrayManager.free(p3);
    arrayManager.free(p4);
    arrayManager.free(p5);



    auto hugeSize = PAGE_SIZE+bigSize;
    auto p6 = arrayManager.alloc(hugeSize, bits);

    assert(PAGE_SIZE*2 == arrayManager.sizeOf(p6));

    arrayManager.free(p6);

    //additional coverage tests
    auto p7 = arrayManager.alloc(32, bits);

    auto p8 = arrayManager.realloc(p7, 64, bits);

    assert(p7 == p8, "Reallocation created a new pointer, but it shouldn't have");

    auto p9 = arrayManager.realloc(p7, 64*3, bits);

    assert(p7 != p9, "Reallocation should have created a new pointer, but it didn't");

    assert(cast(uint)bits == arrayManager.getAttr(p7), "Get bits aren't the same!");

    assert(0b1111 == arrayManager.setAttr(p7, 0b0100), "Set bits aren't the same!");

    assert(0b1010 == arrayManager.clrAttr(p7, 0b0101), "Clear bits aren't the same!");

    assert(p7 == arrayManager.addrOf(p7), "Addresses aren't the same!");
    assert(p7 == arrayManager.addrOf(p7+50), "Addresses aren't the same!");

    arrayManager.free(p7);
    arrayManager.free(p9);
}

class ObjectManager: TypeManager
{
    //A structure to describe a bucket based on block and index
    struct BucketIndex
    {
        int block = -1;
        int bucket = -1;

        static const BucketIndex None;
    }

    //buckets used for array memory allocations
    struct Bucket
    {
        //variable size array for attributes
        ubyte* attributes;
        uint freeMap;
        uint markMap;
        void* memory;
        size_t objectSize;
        BucketIndex nextBucket;

        this(void* mem, size_t oSize, uint fmap, void* arrayLoc) nothrow @nogc
        {
            attributes = cast(ubyte*)arrayLoc;
            memory = mem;
            objectSize = oSize;
            freeMap = fmap;
        }

        void* alloc(ubyte bits) nothrow
        {
            auto pos = bsf(freeMap);

            //set the attributes, remove the free slot, and mark it as found
            attributes[pos] = bits;
            freeMap &= ~(1 << pos);
            markMap |= (1 << pos);

            void* actualLocation = memory + pos * objectSize;

            return actualLocation;
        }

        void* realloc(void* p, ubyte attr) nothrow
        {
            auto pos = (p - memory) / objectSize;

            //if this pointer is currently an object, just reset the attribute
            if((~freeMap) & (1 << pos))
            {
                attributes[pos] = attr;
                return p;
            }

            //otherwise, allocate some space for it
            return alloc(attr);

        }

        uint getAttr(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / objectSize;
            if((~freeMap) & (1 << pos))
                return attributes[pos];

            return 0;
        }

        uint setAttr(void* p, ubyte mask) nothrow @nogc
        {
            auto pos = (p - memory) / objectSize;
            if((~freeMap) & (1 << pos))
            {
                attributes[pos] |= mask;
                return attributes[pos];
            }

            return 0;
        }

        uint clrAttr(void* p, ubyte mask) nothrow @nogc
        {
            auto pos = (p - memory) / objectSize;
            if((~freeMap) & (1 << pos))
            {
                //the compiler sure is dumb
                attributes[pos] &= cast(ubyte)(~cast(int)mask);
                return attributes[pos];
            }

            return 0;
        }

        void* addrOf(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / objectSize;
            if((~freeMap) & (1 << pos))
            {
                return memory + pos * objectSize;
            }

            return null;
        }

        size_t sizeOf(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / objectSize;
            if((~freeMap) & (1 << pos))
            {
                return objectSize;
            }

            return 0;
        }

        BlkInfo query(void* p) nothrow @nogc
        {
            BlkInfo ret;

            auto pos = (p - memory) / objectSize;

            if(~freeMap & (1 << pos))
            {
                ret.base = memory + pos * objectSize;
                ret.size = objectSize;
                ret.attr = attributes[pos];
            }

            return ret;
        }

        void free(void* p) nothrow @nogc
        {
            auto pos = (p - memory) / objectSize;

            if((~freeMap) & (1 << pos))
            {
                freeMap |= (1 << pos);
            }
        }

        void sweep() nothrow
        {
            auto toFree = markMap ^ ~freeMap;

            // for each block not marked, free it
            while (toFree)
            {
                auto pos = bsf(toFree);
                freeMap |= (1 << pos);

                if (attributes[pos] & BlkAttr.FINALIZE || attributes[pos] & BlkAttr.STRUCTFINAL)
                {
                    rt_finalizeFromGC(memory + pos * objectSize, objectSize, attributes[pos]);
                }

                toFree &= ~(1 << pos);
            }
        }

        void prepare() nothrow @nogc
        {
            auto mm = markMap;
            auto fm = freeMap;

            //potentially set some spots as "found" so that the sweep logic is simpler
            if(objectSize <= 128)
                markMap = 0;
            else if(objectSize <= 256)
                markMap = ~cast(uint)ushort.max;
            else if(objectSize <= 512)
                markMap = ~cast(uint)ubyte.max;
            else if(objectSize <= 1024)
                markMap = ~cast(uint)0b1111;
            else if(objectSize <= 2048)
                markMap = ~cast(uint)0b11;
            else
                markMap = ~cast(uint)(1);
        }

        bool testMarkAndSet(void* ptr) nothrow @nogc
        {
            auto pos = (ptr - memory) / objectSize;
            uint markBit = 1 << pos;

            if (markMap & markBit)
                return true;

            markMap |= markBit;
            return false;
        }

        bool isMarked(void* ptr) nothrow @nogc
        {
            auto pos = (ptr - memory) / objectSize;
            uint markBit = 1 << pos;

            if((~freeMap) & (1 << pos))
                return (markMap & markBit) ? true : false;

            return false;
        }
    }

    struct ObjectBlock
    {
        BlockManager block;
        Array!(Bucket) buckets;

        this(void* blockAddress, ubyte objectsPerBucket) nothrow @nogc
        {
            block = BlockManager(blockAddress);
            buckets.init(objectsPerBucket);
        }
    }

    Array!(ObjectBlock) blocks;

    ubyte objectsPerBucket;
    ubyte bucketsPerPage;
    uint freeMap;//the initial freemap

    int currentBlock = -1;
    BucketIndex currentBucket = {-1, -1};
    BucketIndex freeList = {-1, -1};

    this(size_t size, const TypeInfo ti, int index) nothrow @nogc
    {
        //need this in order to correctly initialize the type info
        super(ti, index);

        objectSize = size;
        auto sz = ti.tsize;
        objectsPerBucket = getObjectsPerBucket(objectSize);
        bucketsPerPage = cast(ubyte)(PAGE_SIZE / (objectSize*objectsPerBucket));

        freeMap = getFreeMap();
        auto rtInfo = cast(size_t*) ti.rtInfo();
        if(rtInfo !is null)
        {
            pointerMap = rtInfo;
        }
        else
        {
            pointerMap = cast(size_t*)rtinfoNoPointers;
        }

        blocks.init();
        addBlock();
    }

    ~this()
    {
        _prepare();
        _sweep();
    }

    void addBuckets() nothrow @nogc
    {
        //if we have any buckets on the free list, just pop one off
        if(freeList != BucketIndex.None)
        {
            currentBucket = freeList;
            freeList = blocks[currentBucket.block].buckets[currentBucket.bucket].nextBucket;
            return;
        }

        auto block = &(blocks[currentBlock]);

        int pageIndex;
        //smallish objects
        if(objectSize <= PAGE_SIZE)
        {
            pageIndex = block.block.allocPage();
        }
        else//not smallish objects at all
        {
            auto pages = cast(int)(objectSize/PAGE_SIZE + ((objectSize%PAGE_SIZE)?1:0));
            pageIndex = block.block.allocPages(pages);
        }

        //allocation failed, get more memory
        if(pageIndex < 0)
        {
            //assume won't happen for now
            int reallybad = 0;
        }

        auto bucketAddress = block.block.pageAddress(pageIndex);

        //allocate the first bucket
        auto bucketIndex = block.buckets.addItem();
        void* arrayPos = &(block.buckets[bucketIndex]) + Bucket.sizeof;

        block.buckets[bucketIndex] = Bucket(bucketAddress,
                                    objectSize, freeMap, arrayPos);


        //set this bucket to be the current one
        currentBucket = BucketIndex(currentBlock, bucketIndex);

        //if more buckets are used per page, add them to the free list
        for(int i = 1; i < bucketsPerPage; ++i)
        {
            auto lastBucket = bucketIndex;
            bucketIndex = block.buckets.addItem();

            bucketAddress+= objectSize*objectsPerBucket;

            arrayPos = &(block.buckets[bucketIndex]) + Bucket.sizeof;
            //arrayPos+=Bucket.sizeof;

            block.buckets[bucketIndex] = Bucket(bucketAddress,
                                    objectSize, freeMap, arrayPos);

            block.buckets[bucketIndex].nextBucket = freeList;
            freeList = BucketIndex(currentBlock, bucketIndex);
        }
    }

    void addBlock() nothrow @nogc
    {
        //get a new block
        auto blockIndex = blocks.addItem();
        blocks[blockIndex] = ObjectBlock(allocator.allocBlock(hashIndex), objectsPerBucket);

        //set it as the current block we're using for allocations
        currentBlock = blockIndex;
    }

    override void* _alloc(size_t size, ubyte bits) nothrow
    {
        if(currentBucket != BucketIndex())
        {
            auto bucket = &(blocks[currentBucket.block].buckets[currentBucket.bucket]);
            void* allocatedMemory = bucket.alloc(bits);

            if(bucket.freeMap == 0)
            {
                currentBucket = bucket.nextBucket;
                if(currentBucket == BucketIndex.None)
                {
                    //instead of making a new bucket for allocation right away
                    //we should tell the collector to make a collection
                    shouldCollect = true;
                }
            }

            return allocatedMemory;
        }

        //otherwise we need to add a bucket for this allocation
        addBuckets();
        return blocks[currentBucket.block].buckets[currentBucket.bucket].alloc(bits);
    }

    override void* _realloc(void* p, size_t size, ubyte bits) nothrow
    {
        import core.stdc.string : memcpy;

        auto bucket = findBucket(p);

        if(size == 0)
        {
            bucket.free(p);
            return null;
        }

        //if the size still fits, keep using it
        if(size == objectSize)
        {
            //checks for existance
            return bucket.realloc(p,bits);
        }

        //could this even happen? Should I throw an error?
        return null;
    }

    override void _free(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.free(p);
    }

    override uint _getAttr(void* p) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.getAttr(p);

        return 0;
    }

    override uint _setAttr(void* p, ubyte mask) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.setAttr(p, mask);

        return 0;
    }

    override uint _clrAttr(void* p, ubyte mask) nothrow @nogc
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.clrAttr(p, mask);

        return 0;
    }

    override void* _addrOf(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.addrOf(p);

        return null;
    }

    override size_t _sizeOf(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.sizeOf(p);

        return 0;
    }

    override BlkInfo _query(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.query(p);

        return BlkInfo.init;
    }

    override BlkInfo _qalloc(size_t size, ubyte bits) nothrow
    {
        BlkInfo ret;

        ret.base = _alloc(size, bits);
        ret.size = objectSize;
        ret.attr = bits;

        return ret;
    }

    override void _prepare() nothrow
    {
        auto ti = info;

        auto blockCount = blocks.itemCount;
        for(int i = 0; i < blockCount; ++i)
        {
            auto block = &(blocks[i]);
            auto bucketCount = block.buckets.itemCount;
            for(int j = 0; j < bucketCount; ++j)
            {
                block.buckets[j].prepare();
            }
        }
    }

    override void _sweep() nothrow
    {

        auto ti = info;

        auto blockCount = blocks.itemCount;
        for(int i = 0; i < blockCount; ++i)
        {
            auto block = &blocks[i];
            auto bucketCount = block.buckets.itemCount;
            for(int j = 0; j < bucketCount; ++j)
            {
                auto bucket = &(block.buckets[j]);
                bucket.sweep();
                auto bucketIndex = BucketIndex(i,j);

                if(bucket.freeMap == freeMap)//the bucket is empty
                {
                    //no good way to tell if all buckets in this page are free.
                    //maybe need another pass after this?


                    //For now, simply add bucket to free list
                    bucket.nextBucket = freeList;
                    freeList = bucketIndex;
                }
                else if(bucket.freeMap)//has a mixture of free and empty spots
                {
                    //set this buckt to be the next one we allocate from (if not already)
                    if(currentBucket != bucketIndex)
                    {
                        bucket.nextBucket = bucketIndex;
                        currentBucket = bucketIndex;
                    }
                }

            }
        }
    }

    override bool _testMarkAndSet(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.testMarkAndSet(p);

        return false;
    }

    override void _scan(ref ScanStack scanStack, void* ptr) nothrow
    {
        auto bucket = findBucket(ptr);

        if(bucket)
        {
            auto startAddress = bucket.addrOf(ptr);
            scanStack.push(ScanRange(startAddress, startAddress + objectSize, pointerMap));
        }

    }

    override bool _isMarked(void* p) nothrow
    {
        auto bucket = findBucket(p);

        if(bucket)
            return bucket.isMarked(p);

        return false;
    }

    ubyte getObjectsPerBucket(size_t objectSize) nothrow @nogc
    {
        if(objectSize <= 128)
            return 32;
        else if(objectSize <= 256)
            return 16;
        else if(objectSize <= 512)
            return 8;
        else if(objectSize <= 1024)
            return 4;
        else if(objectSize <= 2048)
            return 2;
        else                     //HUGE
            return 1;
    }

    uint getFreeMap() nothrow @nogc
    {
        final switch(objectsPerBucket)
        {
            case 32:
                return uint.max;
            case 16:
                return ushort.max;
            case 8:
                return ubyte.max;
            case 4:
                return 0b1111;
            case 2:
                return 0b11;
            case 1:
                return 1;
        }
    }

    Bucket* findBucket(void* ptr) nothrow @nogc
    {
        auto cap = blocks.itemCount;

        int blockIndex = -1;
        int pageIndex = -1;
        for(int i = 0; i < cap; ++i)
        {
            if(blocks[i].block.contains(ptr))
            {
                blockIndex = i;
                break;
            }
        }

        if(blockIndex < 0)
        {
            return null;
        }

        if(objectSize <= PAGE_SIZE)
        {

            auto blockStart = blocks[blockIndex].block.startAddress;
            pageIndex = cast(int)((ptr-blockStart)/PAGE_SIZE);
            auto pageStart = blockStart + pageIndex * PAGE_SIZE;
            auto objectNumber = (ptr-pageStart)/objectSize;

            auto bucketIndex = bucketsPerPage*pageIndex + objectNumber/objectsPerBucket;

            return &blocks[blockIndex].buckets[bucketIndex];
        }

        auto start = blocks[blockIndex].block.startAddress;
        int bucketIndex = cast(int)((ptr - start)/objectSize);
        return &blocks[blockIndex].buckets[bucketIndex];
    }
}

unittest
{
    import gc.impl.type.typehash;

    GCAllocator allocator;
    allocator.initialize();
    TypeManager.allocator = &allocator;

    TypeHash typeHash;
    typeHash.initialize();

    struct BigObject
    {
        long[1024] bigArray;
    }

    class TestClass
    {
        int testMember;
    }



    //request the manager for allocating integers
    auto intManager = typeHash.getTypeManager(int.sizeof, typeid(int));

    assert(cast(ObjectManager)intManager !is null, "The returned manager was not an ObjectManager.");

    ubyte bits = 0b1011;

    //allocate for the first time
    void* p = intManager.alloc(int.sizeof, bits);

    assert(int.sizeof == intManager.sizeOf(p));

    BlkInfo info = {p, int.sizeof, bits};
    assert(info == intManager.query(p), "Didn't get the correct info about allocation.");

    intManager.free(p);
    assert(0 == intManager.sizeOf(p));

    //allocate multiple times in a row;

    void* p1 = intManager.alloc(int.sizeof, bits);
    void* p2 = intManager.alloc(int.sizeof, bits);

    assert(int.sizeof == intManager.sizeOf(p1));
    assert(int.sizeof == intManager.sizeOf(p2));

    info = BlkInfo(p1, int.sizeof, bits);
    assert(info == intManager.query(p1), "Didn't get the correct info about allocation.");
    info = BlkInfo(p2, int.sizeof, bits);
    assert(info == intManager.query(p2), "Didn't get the correct info about allocation.");


    intManager.free(p1);
    intManager.free(p2);
    assert(0 == intManager.sizeOf(p1));
    assert(0 == intManager.sizeOf(p2));


    //request the manager for allocating integers
    auto bigManager = typeHash.getTypeManager(BigObject.sizeof, typeid(BigObject));
    assert(cast(ObjectManager)bigManager !is null, "The returned manager was not an ObjectManager.");

    auto p3 = bigManager.alloc(BigObject.sizeof, bits);
    assert(BigObject.sizeof == bigManager.sizeOf(p3));

    bigManager.free(p3);
    assert(0 == bigManager.sizeOf(p3));

    //additional coverage tests
    auto p7 = intManager.alloc(int.sizeof, bits);

    auto p8 = intManager.realloc(p7, int.sizeof, bits);

    assert(p7 == p8, "Reallocation created a new pointer, but it shouldn't have");

    assert(cast(uint)bits == intManager.getAttr(p7), "Get bits aren't the same!");

    assert(0b1111 == intManager.setAttr(p7, 0b0100), "Set bits aren't the same!");

    assert(0b1010 == intManager.clrAttr(p7, 0b0101), "Clear bits aren't the same!");

    assert(p7 == intManager.addrOf(p7), "Addresses aren't the same!");
    assert(p7 == intManager.addrOf(p7+1), "Addresses aren't the same!");

    intManager.free(p7);
}

version(all)
{
struct Tester
{
    void init()
    {
        auto raw = new RawManager(0);
        auto array = new ArrayManager(typeid(int[]), 0);
        auto object = new ObjectManager(int.sizeof, typeid(int), 0);
    }
}
}