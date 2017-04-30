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
    /// The number of objects held by the bucket
package:
    void* memory; //a pointer to the memory used by this bucket to hold the objects
    size_t objectSize; //size of each object
    size_t pointerMap; //the bitmap describing what words are pointers
    ubyte* attributes; //the attributes per object
    uint freeMap; //the bitmap of all free objects in this bucket
    uint markMap; //the bitmap of all object that have been found during a collection
    ubyte numberOfObjects;
    bool arrayType;
    //space for two more bytes for this allignment

public:

    /// TypeBucket Constructor
    this(size_t size, ubyte numberOfObjects, size_t pointerMap) nothrow
    {
        objectSize = size;
        this.numberOfObjects = numberOfObjects;

        freeMap = 0;
        markMap = 0;

        this.pointerMap = pointerMap;


        memory = halloc(numberOfObjects*objectSize);
        attributes = cast(ubyte*)salloc(ubyte.sizeof * numberOfObjects);
    }

    /**
     * Cleans up the object held by the bucket.
     *
     * Since the memory the bucket uses is allocated elsewhere, it does not free
     * it.
     */
    void dtor()
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