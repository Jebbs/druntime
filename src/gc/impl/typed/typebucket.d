/*
 * Contains structures for TypeBuckets and TypeManagers
 */

module gc.impl.typed.typebucket;

static import core.memory;
alias BlkAttr = core.memory.GC.BlkAttr;
alias BlkInfo = core.memory.GC.BlkInfo;

import core.bitop;

import gc.impl.typed.systemalloc;


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
struct TypeBucket
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


//this is here to help me think about code stuffs
enum BucketInfo: ubyte
{
    NORMAL_TYPE = 0b0000,
    RAW_MEMORY  = 0b0001,
    ARRAY_TYPE  = 0b0010,
    FINALIZE    = 0b0100
}

//class to get me thinking about design of different kinds of Buckets
class Bucket
{
    void* memory; //a pointer to the memory used by this bucket to hold the objects
    ubyte* attributes;
    size_t objectSize; //size of each object
    size_t pointerMap; //the bitmap describing what words are pointers
    uint freeMap; //the bitmap of all free objects in this bucket
    uint markMap; //the bitmap of all object that have been found during a collection
    ubyte numberOfObjects;

    ~this()
    {
        markMap = 0;
        sweep();
    }

    /**
     * Checks the freemap to see if this bucket is full.
     */
    abstract bool isFull() nothrow;


    bool empty() nothrow
    {
        return freeMap == 0;
    }

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

    void* addrOf(void* p) nothrow
    {
        //assume that p is one of these objects
        return memory + ((p - memory) / objectSize) * objectSize;
    }

    abstract BlkInfo query(void* p) nothrow;


    abstract void sweep() nothrow;

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
        //need to test if p points to the base or not

        return attributes[(p - memory) / objectSize];
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        //need to test if p points to the base or not

        attributes[(p - memory) / objectSize] |= mask;

        return attributes[(memory - p) / objectSize];
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        //need to test if p points to the base or not

        attributes[(p - memory) / objectSize] &= ~mask;

        return attributes[(memory - p) / objectSize];
    }

}


class RawBucket: Bucket
{

    this(size_t size) nothrow
    {
        objectSize = size;
        attributes = cast(ubyte*)salloc(ubyte.sizeof);
    }
    /**
     * Checks the freemap to see if this bucket is full.
     */
    override bool isFull() nothrow
    {
        return (freeMap !=0);
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
        if(markMap == 0)
            freeMap = 0;
    }
}

class ArrayBucket: Bucket
{

    this(size_t size) nothrow
    {
        objectSize = size;
        attributes = cast(ubyte*)salloc(ubyte.sizeof);
    }
    /**
     * Checks the freemap to see if this bucket is full.
     */
    override bool isFull() nothrow
    {
        return (freeMap !=0);
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
        if(markMap == 0)
            freeMap = 0;
    }
}