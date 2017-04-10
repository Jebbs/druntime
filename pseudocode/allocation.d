module allocation;

import core.sync.mutex;
import core.stdc.string;


//defined in gc.os module. These are designed to allocate pages at a time.
void *os_mem_map(size_t nbytes) nothrow;
int os_mem_unmap(void *base, size_t nbytes) nothrow;

enum PAGE_SIZE = 4096;//4kb

//defined in TypeGC class for internal use

///system alloc for internal structures
void* salloc(size_t size);
///heap alloc for GC managed memory
void* halloc(size_t size);

struct TypeBucket
{
    size_t objectSize;
    void* memory;
    size_t pointerMap;
    uint freeMap;
    //other members

    this(size_t objectSize, size_t pointerMap, void* memory)
    {
        this.objectSize = objectSize;
        this.pointerMap = pointerMap;
        this.memory = memory;
    }

    ///get some memory from the bucket
    void* alloc(uint bits)
    {
        //
        //return memory + other stuff
    }

    bool isFull()
    {
        return (freeMap == freeMap.max);//check if all bits are set
    }
}

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
    const size_t pointerMap;
    const size_t objectSize;

    Mutex mutex;

    bool isArrayType;

    //the start of the linked list
    TypeNode* buckets;
    //the bucket for new allocations
    //(may not necessarily be the last bucket in the list)
    TypeNode* allocateBucketNode;

    /**
     * Construct a new TypeManager.
     *
     * This constructor also creates an empty bucket for allocations.
     */
    this(size_t objectSize, const TypeInfo ti)
    {
        //create a new Node
        buckets = cast(BucketNode*)salloc(TypeNode.sizeof);
        buckets.next = null;

        //create a new Type Bucket
        buckets.bucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

        auto rtInfo = cast(const(size_t)*)ti.rtInfo();
        if(rtInfo !is null)
        {
            //copy the pointer bitmap embedded in the run time info
            pointerMap = rtInfo[1];
        }
        this.objectSize = objectSize;

        //Check to see if the type info describes an array type
        //this cast will fail if ti doesn't describe an array

        isArrayType = (cast(TypeInfo_Array)ti !is null)?true:false;

        if(isArrayType)
        {
            //do special stuff because it's an array

            //create a type bucket with only one "object"

            //mark it has being an array
        }
        else
        {
            //get the heap memory for the bucket
            void* bucketMemory = halloc(TypeBucket.ObjectsPerBucket*objectSize);

            //initialize the bucket
            *(buckets.bucket) = TypeBucket(objectSize ,pointerMap, bucketMemory);
        }

        //assign the new node as the one we'll use to allocate
        allocateBucketNode = buckets;

        //create the mutex
        //this is done in this way because Mutex is a class, and would normally
        //use the GC to allocate

        auto p = salloc(__traits(classInstanceSize,Mutex));
        auto init = typeid(Mutex).initializer();

        mutex = cast(Mutex) memcpy(p, init.ptr, init.length);

        mutex.__ctor();//call the constructor explicitly

    }

    void* alloc(uing bits)
    {
        mutex.lock();
        //will call mutex.unlock() at the end of the scope
        scope(exit) mutex.unlock();

        return getBucket().alloc(bits);
    }

    TypeBucket* getBucket()
    {
        //make sure we have a bucket that can store new objects
        while(allocateBucketNode.bucket.isFull())
        {
            if(allocateBucketNode.next is null)
            {
                if(isArrayType)
                {
                    //do special stuff because it's an array

                    //create a type bucket with only one "object"

                    //mark it has being an array

                }
                else
                {

                    //create a new Node
                    BucketNode* newNode = cast(BucketNode*)salloc(TypeNode.sizeof);
                    newNode.next = null;

                    //create a new Type Bucket
                    newNode.bucket = cast(TypeBucket*)salloc(TypeBucket.sizeof);

                    //get the heap memory for the bucket
                    void* bucketMemory = halloc(TypeBucket.ObjectsPerBucket*objectSize);

                    //initialize the bucket
                    *(newNode.bucket) = TypeBucket(objectSize ,pointerMap,
                                                   bucketMemory);

                    //put it in the linked list
                    allocateBucketNode.next = newNode;
                    //set it as where we allocate from
                    allocateBucketNode = newNode;
                }

                break;
            }

            allocateBucketNode = allocateBucketNode.next;
        }

        return allocateBucketNode.bucket;
    }

}


//approx. 50 unique data TypeStorage, assume that is enough to begin with?
//(make it configurable)
uint hashSize = 101;

TypeManager[] hashArray;

void hashInit()
{
    import core.stdc.string: memset;

    //allocate memory for the hash

    uint numberOfPages = getNumberOfPagesNeeded(hashSize*TypeStorage.sizeof);

    //keep this to free memory later
    size_t hashMemorySize = numberOfPages*PAGE_SIZE;
    void* memory = os_mem_map(hashMemorySize);

    //pretend the memory is actually an array
    hashArray = (cast(TypeManager*)memory)[0 .. hashSize];

    memset(memory, 0, hashSize*TypeStorage.sizeof); //set everything to zero!

}

///gets how many minimum pages are needed to store this number of bytes
//this is used to set up the storage area used by the hash table
uint getNumberOfPagesNeeded(size_t bytes)
{
    uint pages = 1;

    while(bytes > pages*PAGE_SIZE)
    {
        pages++;
    }

    return pages;

}

//perform a simple double hash. Should be enough, but can be optimized later
size_t hashFunc(size_t hash, uint i) nothrow
{
    return ((hash%hashSize) + i*(hash % 7))%hashSize;
}

/**
 * Search by type to find the manager for this type
 */
ref TypeManager getTypeManager(size_t size, const TypeInfo ti)
{
    if(ti is null)
    {
        //get a Manager for untyped memory?
    }

    uint attempts = 0;

    size_t hash = ti.toHash();

    while(true)
    {
        auto pos = hashFunc(hash, attempts);

        if(hashArray[pos].info is null)
        {
            hashArray[pos] = TypeManager(size, ti);

            return hashArray[pos];
        }
        else if(hashArray[pos].info is ti)
        {
            return hashArray[pos];
        }

        attempts++;
    }
}


/**
 * This is the malloc for the GC class. This is to demostrate what an allocation
 * would look like.
 */
void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
{

    if(ti is null)
        //do something special

    TypeManager typeManager = getTypeManager(size, ti);

    return typeManager.alloc(bits);
}
