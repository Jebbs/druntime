/*
 * Contains structures for TypeBuckets and TypeManagers
 */

module gc.impl.typed.typebucket;

static import core.memory;
alias BlkAttr = core.memory.GC.BlkAttr;
alias BlkInfo = core.memory.GC.BlkInfo;

import core.bitop;

import gc.impl.typed.systemalloc;
import gc.impl.typed.scan;


extern (C)
{
    // to allow compilation of this module without access to the rt package,
    // make these functions available from rt.lifetime

    /// Call the destructor/finalizer on a given object.
    void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;
    /// Check if the object at this memroy has a destructor/finalizer.
    int rt_hasFinalizerInSegment(void* p, size_t size, uint attr, in void[] segment) nothrow;
}


/**
 * TypeBucket is a structure that defines a bucket holding a single type.
 *
 * This structure uses information about the type in order to perform some cool
 * things.
 */
struct TypeBucketProto
{
package:
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

        memory = halloc(numberOfObjects*objectSize);
        attributes = cast(ubyte*)salloc(ubyte.sizeof * numberOfObjects);
    }

    /**
     * Cleans up the object held by the bucket.
     *
     * Since the memory the bucket uses is allocated elsewhere, it does not free
     * it.
     */
    void dtor() nothrow
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

    bool empty() nothrow
    {
        return freeMap == 0;
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

    void* addrOf(void* p) nothrow @nogc
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
        //run finalizers for all non-marked objects (if they need it)

        //mark those objects as freed

        markMap = ~markMap;
        //find the position, run finalizer, clear bits



        for(auto pos = bsf(markMap); markMap != 0; markMap &= ~(1 << pos), pos = bsf(markMap))
        {


            if((freeMap & (1 << pos)) == 0)
                continue;

            //check if needs finalization
            if (attributes[pos] & BlkAttr.FINALIZE || attributes[pos] & BlkAttr.STRUCTFINAL)
            {
                rt_finalizeFromGC(memory + pos * objectSize, objectSize, attributes[pos]);
            }

            freeMap &= ~(1 << pos);
        }

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
    bool containsObject(void* p) nothrow @nogc
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


//this is here to help me think about code stuffs
enum BucketInfo: ubyte
{
    NORMAL_TYPE = 0b0000,
    RAW_MEMORY  = 0b0001,
    ARRAY_TYPE  = 0b0010
}

//class to get me thinking about design of different kinds of Buckets
class TypeBucket
{
    void* memory; //a pointer to the memory used by this bucket to hold the objects
    ubyte* attributes;
    size_t objectSize; //size of each object or the size of the bucket if there is only one object
    size_t pointerMap; //the bitmap describing what words are pointers
    uint freeMap; //the bitmap of all free objects in this bucket
    uint markMap; //the bitmap of all object that have been found during a collection
    ubyte numberOfObjects;

    ~this() nothrow
    {
        markMap = 0;
        sweep();
    }

    void dtor() nothrow
    {
        markMap = 0;
        sweep();
    }

    /**
     * Checks the freemap to see if this bucket is full.
     */
    abstract bool isFull() nothrow;


    /**
     * Provide some memory for the GC to create a new object.
     */
    abstract void* alloc(uint bits) nothrow;

    /**
     * Run the finalizer on the object stored at p, and then sets it as free in
     * the freeMap.
     *
     * This function assumes that the pointer is within this bucket.
     */
    abstract void free(void* p) nothrow;

    /**
     * Get information about the block of memory containing p.
     */
    abstract BlkInfo query(void* p) nothrow;

    /**
     * Perform a sweep of the bucket, freeing any unreachable objects.
     *
     * After this function is called, the markMap will be reset and the freeMap
     * will be updated.
     */
    abstract void sweep() nothrow;

    /*
     * Select the memory that will need to be scanned further.
     *
     * Params:
     *  scanStack = the to scan stack.
     *  ptr = the pointer to the object that may contain pointers
     */
    abstract void scan(ref ScanStack scanStack, void* ptr) nothrow;

    /*
     * Get the allocated size of a pointer. If p is an interior pointer, this
     * function returns 0.
     */
    size_t sizeOf(void* ptr) nothrow @nogc
    {
        auto pos = (ptr - memory) / objectSize;

        if(ptr == memory + pos*objectSize)
            return objectSize;

        return 0;
    }

    /**
     * Check if this bucket is empty.
     */
    bool empty() nothrow
    {
        return freeMap == 0;
    }

    /**
     * Get the base address of the block containing p.
     */
    void* addrOf(void* p) nothrow @nogc
    {
        //assume that p is one of these objects
        return memory + ((p - memory) / objectSize) * objectSize;
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

        //this should test the attributes to make sure we are ok with interior pointers

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
    bool containsObject(void* p) nothrow @nogc
    {
        if (p >= memory && p < memory + objectSize * numberOfObjects)
            return true;

        return false;
    }

    uint getAttr(void* p) nothrow
    {
        //need to test if p points to the base or not

        auto pos = (p - memory) / objectSize;

        if(p == memory + pos*objectSize)
            return attributes[pos];

        return 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        //need to test if p points to the base or not

        auto pos = (p - memory) / objectSize;

        if(p == memory + pos*objectSize)
        {
            attributes[(p - memory) / objectSize] |= mask;

            return attributes[(memory - p) / objectSize];
        }

        return 0;
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        //need to test if p points to the base or not

        auto pos = (p - memory) / objectSize;

        if(p == memory + pos*objectSize)
        {

            attributes[(p - memory) / objectSize] &= ~mask;

            return attributes[(memory - p) / objectSize];
        }

        return 0;
    }

}

///Bucket used in conjunction with raw memory allocations.
class RawBucket: TypeBucket
{

    static RawBucket newBucket(size_t size, void* memory) nothrow
    {
        import core.stdc.string : memcpy;


        //allocate memory for the bucket
        auto ptr = salloc(__traits(classInstanceSize, RawBucket));

        //get the initializer
        auto init = typeid(RawBucket).initializer();

        //create the instance
        auto bucket = cast(RawBucket)memcpy(ptr, init.ptr, init.length);

        bucket.__ctor(size, memory);

        return bucket;
    }


    this(size_t size, void* memory) nothrow
    {
        objectSize = size;
        attributes = cast(ubyte*)salloc(ubyte.sizeof);
        pointerMap = size_t.max;
        numberOfObjects = 1;

        this.memory = memory;
    }
    /**
     * Checks the freemap to see if this bucket is full.
     */
    override bool isFull() nothrow
    {
        return (freeMap == 1);
    }

    /**
     * Provide some memory for the GC to create a new object.
     */
    override void* alloc(uint bits) nothrow
    {
        *attributes = cast(ubyte)bits;
        freeMap = 1;
        return memory;
    }

    /**
     * Run the finalizer on the object stored at p, and then sets it as free in
     * the freeMap.
     *
     * This function assumes that the pointer is within this bucket.
     */
    override void free(void* p) nothrow
    {
        freeMap = 0;
    }

    override BlkInfo query(void* p) nothrow
    {
        BlkInfo ret;

        ret.base = memory;
        ret.size = objectSize;
        ret.attr = *attributes;

        return ret;
    }


    override void sweep() nothrow
    {
        if(markMap)
            return;

        if(markMap == 0)
            freeMap = 0;
    }

    override void scan(ref ScanStack scanStack, void* ptr) nothrow
    {
        scanStack.push(ScanRange(memory, memory + objectSize, size_t.max));
    }
}

///Bucket used in conjumction with array allocations.
class ArrayBucket: TypeBucket
{
    //If the object this array contains is a pointer type or not.
    bool isObjectPointerType;
    ///the size of individual objects in the array
    size_t arrayObjectSize;
    //create an alias so that the code looks more natural
    alias arraySize = objectSize;
    this(size_t size, bool pointerType, size_t pointerMap,
         size_t arrayObjectSize, void* memory) nothrow
    {
        objectSize = size;
        attributes = cast(ubyte*)salloc(ubyte.sizeof);

        isObjectPointerType = pointerType;

        this.pointerMap = pointerMap;
        this.arrayObjectSize= arrayObjectSize;

        numberOfObjects = 1;

        this.memory = memory;
    }

    /**
     * Checks the freemap to see if this bucket is full.
     */
    override bool isFull() nothrow
    {
        return (freeMap == 1);
    }

    /**
     * Provide some memory for the GC to create a new object.
     */
    override void* alloc(uint bits) nothrow
    {
        *attributes = cast(ubyte)bits;
        freeMap = 1;
        return memory;
    }

    /**
     * Run the finalizer on the object stored at p, and then sets it as free in
     * the freeMap.
     *
     * This function assumes that the pointer is within this bucket.
     */
    override void free(void* p) nothrow
    {
        markMap = 0;
        sweep();
    }

    override BlkInfo query(void* p) nothrow
    {
        BlkInfo ret;

        ret.base = memory;
        ret.size = objectSize;
        ret.attr = *attributes;

        return ret;
    }


    override void sweep() nothrow
    {
        if(markMap)
            return;

        //check if pointer type or type doesn't need finalizer
        if(isObjectPointerType || ~(*attributes) & BlkAttr.FINALIZE ||
                ~(*attributes) & BlkAttr.STRUCTFINAL)
        {
            //don't worry about freeing individual objects

            freeMap = 0;
            markMap = 0;
            return;
        }


        auto arrayPos = getArrayStart();
        auto arrayEnd = arrayPos + getArrayLength()*arrayObjectSize;
        for (; arrayPos < arrayEnd; arrayPos += arrayObjectSize) //each object in the array
        {
            rt_finalizeFromGC(arrayPos + arrayObjectSize, objectSize, *attributes);
        }

        freeMap = 0;
        markMap = 0;
    }

    /**
     * Find the start of our array, depending on the size.
     *
     * This is more or less copied from lifetime.d
     */
    void* getArrayStart() nothrow
    {
        enum : size_t
        {
            PAGESIZE = 4096,
            BIGLENGTHMASK = ~(PAGESIZE - 1),
            LARGEPREFIX = 16, // 16 bytes padding at the front of the array
        }

        return memory + ((objectSize & BIGLENGTHMASK) ? LARGEPREFIX : 0);
    }

    /**
     * Get the number of objects contained in this array.
     *
     * Because this is being called from the GC, we should be able to ignore the
     * possibility of a TypeInfo instance being embedded in the array (see
     * structTypeInfoSize on line 215 in runtime.d).
     *
     * This function was more or less copied from __arrayAllocLength in
     * lifetime.d.
     */
    size_t getArrayLength() pure nothrow
    {
        enum: size_t
        {
            PAGESIZE = 4096,
            SMALLPAD = ubyte.sizeof,
            MEDPAD = ushort.sizeof,
        }

        if(objectSize <= 256)
            return *cast(ubyte *)(memory + objectSize - SMALLPAD);

        if(objectSize < PAGESIZE)
            return *cast(ushort *)(memory + objectSize - MEDPAD);

        return *cast(size_t *)(memory);
    }

    override void scan(ref ScanStack scanStack, void* ptr) nothrow
    {
        auto arrayPos = getArrayStart();
        auto arrayLength = getArrayLength();

        //add the set and scan conservatively since everything is a pointer anyway
        if(isObjectPointerType)
        {
            scanStack.push(ScanRange(arrayPos, arrayPos + (arrayLength*arrayObjectSize),
                           size_t.max));
        }
        else
        {

            //no pointers
            if(pointerMap == 0)
                return;

            //go over each object in the array
            for(uint i = 0;i < arrayLength; i++, arrayPos+= arrayObjectSize)
            {
                //this needs to be fixed because large arrays are a problem!
                size_t tempMap = pointerMap;

                //push that object into the scan stack
                scanStack.push(ScanRange(arrayPos, arrayPos + arrayObjectSize, pointerMap));
            }
        }
    }

}

///Bucket used in conjumction with object allocations.
class ObjectsBucket: TypeBucket
{
    ///what the freeMap looks like when it is full
    uint fullMap;

    this(ubyte numberOfObjects, uint fullMap, size_t objectSize,
    size_t pointerMap, void* memory) nothrow
    {
        //how many objects a small bucket will hold
        this.numberOfObjects = numberOfObjects;

        this.objectSize = objectSize;
        attributes = cast(ubyte*)salloc(ubyte.sizeof * numberOfObjects);
        this.pointerMap = pointerMap;

        this.fullMap = fullMap;

        this.memory = memory;
    }
    /**
     * Checks the freemap to see if this bucket is full.
     */
    override bool isFull() nothrow
    {
        return (freeMap  == fullMap);
    }

    /**
     * Provide some memory for the GC to create a new object.
     */
    override void* alloc(uint bits) nothrow
    {
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
    override void free(void* p) nothrow
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

    override BlkInfo query(void* p) nothrow
    {
        BlkInfo ret;

        ret.base = memory;
        ret.size = objectSize;
        ret.attr = *attributes;

        return ret;
    }


    override void sweep() nothrow
    {
        if(markMap == 0)
            freeMap = 0;
    }

    override void scan(ref ScanStack scanStack, void* ptr) nothrow
    {

        //get base? or assume that ptr points to the base of an object

        scanStack.push(ScanRange(ptr, ptr + objectSize, pointerMap));
    }
}

