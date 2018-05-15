module gcalloc;
import core.internal.spinlock;
import core.bitop;


enum PAGE_SIZE = 4096;//4kb

version(Windows)
{

}
else version(Posix)
{

}
else
{
    static assert(false, "Unsupported platform");
}

/*
 * Reserve an address space from the OS, but do not allocate it.
 *
 * Params:
 *  n = number of bytes, multiple of page size.
 */
void* mem_reserve(size_t n) nothrow @nogc
{
    return null;
}

/*
 * Commit a range of memory to the program, allowing it to be used.
 * This function assumes that the memory range has already been reserved.
 *
 * Prams:
 *  base = the start of the reserved address range.
 *  n    = number of bytes, multiple of page size.
 */
void* mem_commit(void * base, size_t n) nothrow @nogc
{
    return null;
}

/*
 * Free a range of memory, returning it back to the OS.
 *
 * Prams:
 *  base = the start of the memory range.
 *  n    = number of bytes, multiple of page size.
 */
void mem_free(void* base, size_t n) nothrow @nogc
{

}


class GC
{
    uint hashSize = 127;//Prime Number (to be configurable)
    TypedManager[hashSize+1] hashArray;//one extra for raw memory
    byte[128] typeMap;//typeMap is a map to the index of a type in the hashArray

    void* heap;
    size_t heapSize = 512*1024*1024*1024;//512GB

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
     * Constructor for the Typed GC.
     */
    this()
    {
        import core.stdc.string: memset;

        //reserve 256GB address space
        heap = mem_reserve(heapSize);
        
        //start the stack with tons of memory so it doesn't overflow
        scanStack = ScanStack(3*PAGE_SIZE);

    }


    //perform a simple double hash. Should be enough, but can be optimized later
    size_t hashFunc(size_t hash, uint i) nothrow
    {
        return ((hash%hashSize) + i*(hash % 7))%hashSize;
    }

    /**
     * Search by type to find the manager for this type
     */
    TypeManager getTypeManager(size_t size, const TypeInfo ti) nothrow
    {
        static auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);
        mutex.lock();

        if(ti !is null)
        {
            uint attempts = 0;
            size_t hash = cast(size_t)(&ti);

            while(true)
            {
                auto pos = hashFunc(hash, attempts);
                if(hashArray[pos].heapSize == 0)//this Manager is unused
                {
                    
                }
            }


        }


        if(ti is null)
            return untypedManager;

        

        while(true)
        {
            auto pos = hashFunc(hash, attempts);

            if(hashArray[pos] is null)
            {

                //check if it is an array type or not
                if(cast(TypeInfo_Array) ti !is null)
                {
                    hashArray[pos] = New!ArrayManager(ti);
                }
                else
                {
                    hashArray[pos] = New!ObjectsManager(size, ti);
                }

                lastManager.next = New!ManagerNode();
                lastManager = lastManager.next;
                lastManager.object = hashArray[pos];
                lastManager.next = null;

                return (hashArray[pos]);
            }
            else if(hashArray[pos].info is ti)
            {
                return (hashArray[pos]);
            }

            attempts++;
        }
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

        TypeManager type = getTypeManager(size, ti);

        //May trigger a collection
        return type.alloc(size, bits);
    }


    TypeBucket* getBucket(void* ptr)
    {
        //4GB chunks are allotted to each Type, so we can mask and shift the address to get the type
        size_t managerPosition = (0xFFFFFFFF00000000&ptr)>>32;

        auto manager = hashArray[typeMap[managerPosition]];
    }


}

//template it for different sizes?
struct TypeBucket
{
    //A pointer to the next bucket to use for allocation once this one is full
    TypeBucket* nextBucket;
    void* memoryBase;

    ubyte attributes[32];//or however many

    uint freeMap;//map of free positions, 1 is free and 0 is used
    uint markMap;//map of marked positions, 1 is marked and 0 is unmarked

    uint fullMap;//map descrribing when this is full(maybe isn't needed)

    bool isFull()
    {
        //if freemap is all 0's, this will return 0
        return cast(bool)(fullMap&freeMap);

        return freeMap?false:true;//if we don't need the full map, this should work
    }

    void* alloc(uint attr)
    {
        //find the next free position
        auto pos = bsf(freeMap);

        //Current attributes use at most 6 bits, so we can use a smaller
        //type internally
        attributes[pos] = cast(ubyte)bits;
        freeMap -= (1 << pos);//remove the bit from the free map
        markMap |= (1 << pos);//add this bit to the mark map << super important! This allows new objects to be allocated after the mark bits have been cleared at collection prep

        //and return the location in memory
        return memory + pos * objectSize;
    }
}

struct Array(T)
{
    T* memory;
    size_t length;
    size_t memoryUsed;

    ref T opIndex(size_t index)
    {
        return memory[index];
    }

    void addNewElement()
    {
        length++;

        //if we need more room for 
        if(length * sizeof(T) > memoryUsed)
            mem_commit(cast(void*)(memory) + memoryUsed, PAGE_SIZE);
    }

}

//should be a class still? Or can I use a union and do runtime checking?
struct TypeManager
{
    //Array of buckets used for this type
    auto buckets = Array!(TypeBucket);

    //The base of the memory used by this type
    void* memoryBase;

    //The current size of the heap, will be initialized to something on first use
    size_t heapSize;

    TypeBucket* allocBucket;

    const(TypeInfo) info; //type info reference for hash comparison
    size_t pointerMap;
    size_t objectSize;
    ubyte ObjectsPerBucket;
    bool isArrayType;
    ubyte pointerMapSize;//used for array scanning

    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

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

    }

    //finds a bucket and grabs memory from it
    void* alloc(uint attributes) nothrow
    {
        if(allocBucket is null)
        {
            //there is always

            //check if we need to ask for a new page from the OS (for heap and buckets)
            uint numberOfPagesUsed;
            buckets.length++;

            if(buckets.length*sizeof(TypeBucket) > numberOfPagesUsed*PAGE_SIZE)
                mem_commit(memoryBase + numberOfPagesUsed*PAGE_SIZE, PAGE_SIZE);//actually commit virtual mem pages to the program

            buckets[buckets.length-1].memoryBase = buckets[buckets.length-2].memoryBase;



        }

        void* retVal = allocBucket.alloc(attributes);
        if(allocBucket.isFull())
            allocBucket = allocBucket.nextBucket;
        return retVal;
    }


    TypeBucket* getBucket(void* ptr)
    {
        uint shift;//don't know how much to shift by yet
        size_t bucketPosition = (0x00000000FFFFFFFF&ptr)>>shift;

        return &buckets[bucketPosition];
    }

    BlkInfo qalloc(uint attributes) nothrow
    {
    }

    void prepare() nothrow
    {
    }

    void sweep() nothrow
    {
    }

}




