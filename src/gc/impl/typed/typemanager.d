

module gc.impl.typed.typemanager;

import core.internal.spinlock;

import gc.impl.typed.systemalloc;
import gc.impl.typed.typebucket;



/**
 *  TypeManager manages the allocations for a specific type.
 */
struct TypeManager
{

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

    //Mutex mutex;
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

    /// Linked list of all buckets managed for this type
    TypeNode* buckets;
    /// Bucket to be used when performing allocations (to avoid searching)
    TypeNode* allocateNode;

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
            }
            else
            {
                auto rtInfo = cast(const(size_t)*) tinext.rtInfo();
                if (rtInfo !is null)
                {
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
        node = cast(TypeNode*)_gc.salloc(TypeNode.sizeof);
        node.next = null;

        //Create SearchNode
        auto newSearchNode = cast(SearchNode*)_gc.salloc(SearchNode.sizeof);
        newSearchNode.left = null;
        newSearchNode.right = null;

        //create TypeBucket
        auto newBucket = cast(TypeBucket*)_gc.salloc(TypeBucket.sizeof);

        //initialize the bucket
        *(newBucket) = TypeBucket(objectSize,ObjectsPerBucket, pointerMap);


        node.bucket = newBucket;
        newSearchNode.bucket = newBucket;

        allocateNode = node;
        _gc.searchNodeInsert(newSearchNode);
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
        node = cast(TypeNode*)_gc.salloc(TypeNode.sizeof);
        node.next = null;

        //Create SearchNode
        auto newSearchNode = cast(SearchNode*)_gc.salloc(SearchNode.sizeof);
        newSearchNode.left = null;
        newSearchNode.right = null;

        //create TypeBucket
        auto newBucket = cast(TypeBucket*)_gc.salloc(TypeBucket.sizeof);

        //calulate the full size of the array. This adds length to the array
        //to make it appendable

        //array size = requested size + (approximate length * 0.3)
        size_t arraySize = cast(size_t)(size + objectSize* cast(size_t)((size/objectSize) * 0.3f));

        //initialize the bucket
        *(newBucket) = TypeBucket(arraySize,ObjectsPerBucket, pointerMap);


        node.bucket = newBucket;
        newSearchNode.bucket = newBucket;

        allocateNode = node;
        _gc.searchNodeInsert(newSearchNode);
    }


    //finds a bucket and grabs memory from it
    void* alloc(uint bits) nothrow
    {
        mutex.lock();
        //will call mutex.unlock() at the end of the scope
        scope (exit)
            mutex.unlock();

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
        int test = 0;
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

}