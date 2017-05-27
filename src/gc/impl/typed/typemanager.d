

module gc.impl.typed.typemanager;

import core.internal.spinlock;

import gc.impl.typed.systemalloc;
import gc.impl.typed.typebucket;
import gc.impl.typed.bucketavl;

//The base class for type managers
class TypeManager
{
    static BucketAVL gcBuckets;//is this ok? or should it be passed?

    struct TypeNode
    {
        TypeBucket bucket;
        TypeNode* next;
    }

    bool needsSweeping;

    

    /// Linked list of all buckets managed for this type
    TypeNode* buckets;

    /// Perform a thread safe allocation.
    abstract void* alloc(size_t size, uint bits) nothrow;

    abstract BlkInfo qalloc(size_t size, uint bits) nothrow;

    abstract void sweep() nothrow;

    void prepare() nothrow
    {
        needsSweeping = true;
    }
}

class RawManager: TypeManager
{
    TypeNode* freeList;

    this() nothrow
    {
        freeList = null;
    }

    override void* alloc(size_t size, uint bits) nothrow
    {
        //mutex.lock();
        //will call mutex.unlock() at the end of the scope
        //scope (exit) mutex.unlock();

        if(needsSweeping)
            sweep();

        size_t allocSize = size;

        if(bits & BlkAttr.APPENDABLE)
            allocSize+= size >> 2;


        if(buckets is null)
        {
            return allocImpl(allocSize, bits);
        }
        else
        {
            if(freeList is null)
                return allocImpl(allocSize, bits);


            TypeNode* last;
            TypeNode* current = freeList;


            for(;current != null; last = current, current = current.next)
            {
                //search through freelist to get a bucket large enough
                if(current.bucket.objectSize >= allocSize)
                {
                    TypeNode* temp = current.next;

                    current.next = buckets;

                    buckets = current;

                    if(last is null)
                        freeList = temp;
                    else
                        last.next = temp;

                    return buckets.bucket.alloc(bits);
                }
            }

            //otherwise allocate new bucket
            return allocImpl(allocSize, bits);
        }

    }

    void* allocImpl(size_t size, uint bits) nothrow
    {
        //create TypeNode
        auto node = New!TypeNode();
        node.next = buckets; //we're going to put this bucket in the front

        void* memory = halloc(size);

        //create TypeBucket
        auto newBucket = New!RawBucket(size, memory);
        node.bucket = newBucket;

        //the new bucket is at the front
        buckets = node;

        gcBuckets.insert(newBucket);

        return newBucket.alloc(bits);
    }

    override BlkInfo qalloc(size_t size, uint bits) nothrow
    {
        BlkInfo ret;

        ret.base = alloc(size, bits);
        ret.size = buckets.bucket.objectSize;
        ret.attr = bits;

        return ret;
    }

    override void sweep() nothrow
    {
        TypeNode* last;
        TypeNode* current = buckets;

        while(current != null)
        {
            current.bucket.sweep();

            //put empty bucket into a freelist
            if(current.bucket.empty())
            {
                TypeNode* temp = current;
                current = current.next;

                //make sure thebucket list is correct
                if(last !is null)
                    buckets = current;
                else
                    last.next = current;

                if(freeList is null)
                    temp.next = null;
                else
                    temp.next = freeList;

                    freeList = temp;
            }
            else
            {
                last = current;
                current = current.next;
            }
        }
    }
}


class TypedManager: TypeManager
{

    this(const TypeInfo ti) nothrow
    {
        info = ti;
    }

    const TypeInfo info; //type info reference for hash comparison
    size_t pointerMap; //a bitmap representing the layout of pointers
    size_t objectSize; //the size of individual objects
}


class ArrayManager: TypedManager
{

    TypeNode* freeList;
    bool pointerType;

    this(const TypeInfo ti) nothrow
    {
        //need this in order to correctly initialize the type info
        super(ti);

        pointerType = ((cast(const TypeInfo_Pointer) ti.next !is null) ||
                   (cast(const TypeInfo_Class) ti.next !is null));

        int breaker1 = 0;
        if(pointerType)
        {
            //if the type is a pointer or reference type, we will always
            //have one indirection to the actual object, which is stored in its
            //own bucket
            objectSize = size_t.sizeof;
            pointerMap = 1;
        }
        else
        {
            auto tinext = ti.next;
            auto rtInfo = cast(const(size_t)*) ti.next.rtInfo();
            if (rtInfo !is null)
            {
                objectSize = cast(ubyte)(rtInfo[0]);
                int breaker = 0;
                //copy the pointer bitmap embedded in the run time info
                pointerMap = rtInfo[1];
            }
            else
            {
                //otherwise we have something that doesn't need to be scanned
                //(it contains no pointers)
                pointerMap = 0;
                objectSize = tinext.tsize;
                int breaker = 0;
            }
        }
    }

    override void* alloc(size_t size, uint bits) nothrow
    {
        //mutex.lock();
        //will call mutex.unlock() at the end of the scope
        //scope (exit) mutex.unlock();

        if(needsSweeping)
            sweep();

        //get some padding for the array

        size_t sz = objectSize;

        size_t padding = ((size/objectSize) >> 2) * objectSize;
        size+=padding;

        if(buckets is null)
        {
            return allocImpl(size, bits);
        }
        else
        {
            if(freeList is null)
                return allocImpl(size, bits);


            TypeNode* last;
            TypeNode* current = freeList;


            for(;current != null; last = current, current = current.next)
            {
                //search through freelist to get a bucket large enough
                if(current.bucket.objectSize >= size)
                {
                    TypeNode* temp = current.next;

                    current.next = buckets;

                    buckets = current;

                    if(last is null)
                        freeList = temp;
                    else
                        last.next = temp;

                    return buckets.bucket.alloc(bits);
                }
            }

            //otherwise allocate new bucket
            return allocImpl(size, bits);
        }

    }

    void* allocImpl(size_t size, uint bits) nothrow
    {
        //create TypeNode
        auto node = New!TypeNode();
        node.next = buckets; //we're going to put this bucket in the front

        void* memory = halloc(size);

        //create TypeBucket
        auto newBucket = New!ArrayBucket(size, pointerType, pointerMap,
            objectSize, memory);
        node.bucket = newBucket;

        //the new bucket is at the front
        buckets = node;

        gcBuckets.insert(newBucket);

        return newBucket.alloc(bits);
    }

    override BlkInfo qalloc(size_t size, uint bits) nothrow
    {
        BlkInfo ret;

        ret.base = alloc(size, bits);
        ret.size = buckets.bucket.objectSize;
        ret.attr = bits;

        return ret;
    }

    override void sweep() nothrow
    {
        TypeNode* last;
        TypeNode* current = buckets;

        while(current != null)
        {
            current.bucket.sweep();

            //put empty bucket into a freelist
            if(current.bucket.empty())
            {
                TypeNode* temp = current;
                current = current.next;

                //make sure the bucket list is correct
                if(last is null)
                    buckets = current;
                else
                    last.next = current;

                if(freeList is null)
                    temp.next = null;
                else
                    temp.next = freeList;

                    freeList = temp;
            }
            else
            {
                last = current;
                current = current.next;
            }
        }
    }
}

class ObjectsManager: TypedManager
{
    ubyte objectsPerBucket;
    uint fullMap; //a bitmap showing what the freeMap will look like when full
    TypeNode* allocateNode;
    this(size_t objectSize, const TypeInfo ti) nothrow
    {
        //need this in order to correctly initialize the type info
        super(ti);

        this.objectSize = objectSize;
        objectsPerBucket = getObjectsPerBucket(objectSize);
        fullMap = getFullMap();
        auto rtInfo = cast(const(size_t)*) ti.rtInfo();
        if(rtInfo !is null)
        {
            pointerMap = rtInfo[1];
        }
        else
        {
            pointerMap = 0;
        }
        createNewBucket(buckets);
    }

    override void* alloc(size_t size, uint bits) nothrow
    {
        //mutex.lock();
        //will call mutex.unlock() at the end of the scope
        //scope (exit) mutex.unlock();

        if(needsSweeping)
            sweep();

        return allocImpl(bits);
    }

    void* allocImpl(uint bits) nothrow
    {
        //make sure we have a bucket that can store new objects
        for(;allocateNode.bucket.isFull(); allocateNode = allocateNode.next)
        {
            if (allocateNode.next is null)
            {
                //creates a new TypeNode and will assign it to allocateNode
                createNewBucket(allocateNode.next);
                break;
            }
        }

        return allocateNode.bucket.alloc(bits);
    }

    override BlkInfo qalloc(size_t size, uint bits) nothrow
    {
        BlkInfo ret;

        ret.base = alloc(size, bits);
        ret.size = buckets.bucket.objectSize;
        ret.attr = bits;

        return ret;
    }

    override void sweep() nothrow
    {
        for(auto cur = buckets; cur != null; cur = cur.next)
        {
            cur.bucket.sweep();
        }
    }

    ubyte getObjectsPerBucket(size_t objectSize) nothrow
    {
        if(objectSize < 64)      //small
        {
            return 32;
        }
        else if(objectSize < 128)//medium
        {
            return 16;
        }
        else if(objectSize < 256)//large
        {
            return 8;
        }
        else                     //HUGE
        {
            return 1;
        }
    }

    uint getFullMap() nothrow
    {

        final switch(objectsPerBucket)
        {
            case 32:
                return uint.max;
            case 16:
                return ushort.max;
            case 8:
                return ubyte.max;
            case 1:
                return 1;
        }
    }

    /**
     * Creates a new TypeBucket for this type and initializes it.
     *
     * In addition to creating the bucket itself, it also
     * inserts a new SearchNode into the search tree.
     *
     * Params:
     *  node = A reference to the end of the linked list.
     */
    void createNewBucket(ref TypeNode* node) nothrow
    {
        //create TypeNode
        node = New!TypeNode();
        node.next = null;

        void* memory = halloc(objectSize*objectsPerBucket);

        //create TypeBucket
        auto newBucket = New!ObjectsBucket(objectsPerBucket,fullMap,
        objectSize, pointerMap, memory);

        node.bucket = newBucket;

        allocateNode = node;
        gcBuckets.insert(newBucket);
    }
}


/**
 *  TypeManager manages the allocations for a specific type.
 */


version(none)
{

struct TypeManagerProto
{
    static BucketAVL gcBuckets;

    struct TypeNode
    {
        TypeBucket* bucket;
        TypeNode* next;
    }

    const TypeInfo info; //type info reference for hash comparison
    size_t pointerMap;
    size_t objectSize;
    ubyte ObjectsPerBucket;
    bool isArrayType;
    ubyte pointerMapSize;//used for array scanning
    bool needsSweeping;

    //Mutex mutex;
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

    /// Linked list of all buckets managed for this type
    TypeNode* buckets;
    /// Bucket to be used when performing allocations (to avoid searching)
    TypeNode* allocateNode;
    //a freelist to be used for array types
    TypeNode* freeList;

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

    ubyte getObjectsPerBucket(size_t objectSize) nothrow
    {
        if(objectSize < 64)      //small
        {
            return 32;
        }
        else if(objectSize < 128)//medium
        {
            return 16;
        }
        else if(objectSize < 256)//big
        {
            return 8;
        }
        else if(objectSize < 512)//very big
        {
            return 4;
        }
        else                     //HUGE
        {
            return 1;
        }
    }

    /**
     * Creates a new TypeBucket for this type and initializes it.
     *
     * In addition to creating the bucket itself, this function creates a
     * TypeNode for the new bucket and assigns it to allocateNode. It also
     * inserts a new SearchNode containing the new bucket into the search
     * tree.
     *
     * Params:
     *  node = A reference to the end of the linked list.
     */
    void createNewBucket(ref TypeNode* node) nothrow
    {
        //create TypeNode
        node = cast(TypeNode*)salloc(TypeNode.sizeof);
        node.next = null;


        //create TypeBucket
        auto newBucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

        //initialize the bucket
        *(newBucket) = TypeBucket(objectSize,ObjectsPerBucket, pointerMap);


        node.bucket = newBucket;

        allocateNode = node;
        gcBuckets.insert(newBucket);
    }

    /**
     * Creates a new TypeBucket for an array and initializes it.
     *
     * In addition to creating the bucket itself, this function creates a
     * TypeNode for the new bucket and assigns it to allocateNode. It also
     * inserts a new SearchNode containing the new bucket into the search
     * tree.
     *
     * Params:
     *  node = A reference to the end of the linked list.
     *  size = the requested size of memory for the array.
     */
    void CreateNewArrayBucket(ref TypeNode* node, size_t size) nothrow
    {
        //create TypeNode
        node = cast(TypeNode*)salloc(TypeNode.sizeof);
        node.next = null;


        //create TypeBucket
        auto newBucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

        //calulate the full size of the array. This adds length to the array
        //to make it appendable

        //array size = requested size + (approximate length * 0.25 * object size)

        size_t padding = ((size/objectSize) >> 2) * objectSize;

        size_t arraySize = size + padding;

        //initialize the bucket
        *(newBucket) = TypeBucket(arraySize,ObjectsPerBucket, pointerMap, pointerMapSize);

        //let the bucket know it is an array
        newBucket.arrayType = true;


        node.bucket = newBucket;

        allocateNode = node;
        gcBuckets.insert(newBucket);
    }

    //finds a bucket and grabs memory from it
    void* alloc(uint bits) nothrow
    {
        mutex.lock();
        //will call mutex.unlock() at the end of the scope
        scope (exit)
            mutex.unlock();

        if(needsSweeping)
            sweep();

        //make sure we have a bucket that can store new objects
        while (allocateNode.bucket.isFull())
        {
            if (allocateNode.next is null)
            {
                //creates a new TypeNode and will assign it to allocateNode
                createNewBucket(allocateNode.next);
                break;
            }

            allocateNode = allocateNode.next;
        }

        return allocateNode.bucket.alloc(bits);
    }

    BlkInfo qalloc(uint bits) nothrow
    {
        BlkInfo ret;
        ret.base = alloc(bits);
        ret.size = allocateNode.bucket.objectSize;
        ret.attr = bits;
        return ret;
    }

    void prepare() nothrow
    {
        needsSweeping = true;
    }

    void sweep() nothrow
    {
        TypeNode start;
        start.next = buckets;
        for(auto cur = &start; cur.next !is null;)
        {
            //sweep the buckets
            cur.next.bucket.sweep();
            if(isArrayType && cur.next.bucket.empty())
            {

                // push into a free list if empty
                TypeNode* temp = cur.next;
                cur.next = cur.next.next;

                if(freeList is null)
                    temp.next = null;
                else
                    temp.next = freeList;

                freeList = temp;
            }
            else
            {
                cur = cur.next;
            }
        }

        if(!isArrayType)
        {
            //set the allocation bucket to the bucket in the list
            allocateNode = buckets;
        }

        needsSweeping = false;
    }

}

}
