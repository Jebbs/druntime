module typebucket;


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
        ubyte objectSize;//size of each object
        uint freeMap;//the bitmap of all free objects in this bucket
        uint markMap;//the bitmap of all object that have been found during a collection
        uint pointerMap;//the bitmap describing what words are pointers
        uint[ObjectsPerBucket] attributes;//the attributes per object

        //one of these might be better than the other, we'll see
        void* memory; //a pointer to the memory used by this bucket to hold the objects

    public:

    /**
     * Initializes the Type bucket.
     *
     * This function is called instead of the constructor because we are using
     * malloc to get the memory for this object.
     */
    void initialize(size_t size, size_t pointerMap, void* memory) nothrow
    {


        //this is ok for now because we will make sure objectSize is large enough
        //to hold the actual size of an object later
        objectSize = cast(typeof(objectSize))size;

        freeMap = 0;
        markMap = 0;

        this.pointerMap = pointerMap;

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