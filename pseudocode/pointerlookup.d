
//describes the boundaries of the GC managed heap
//these are used when searching for pointers (if not in these bounds, we won't perform a search)
void* memBottom, memTop;


///system alloc for internal structures
void* salloc(size_t size);
///heap alloc for GC managed memory
void* halloc(size_t size);

struct TypeBucket
{
    void* memory;
    ubyte ObjectsPerBucket;
    size_t objectSize;

    bool contains(void* ptr)
    {
        return (ptr >= memory && ptr < memory + (objectSize*ObjectsPerBucket));
    }
}

/**
 * BucketNode describes a node in a binary tree.
 */
struct BucketNode
{
    TypeBucket* bucket;
    BucketNode* left;
    BucketNode* right;
}

/// This is the root node in a binary tree
BucketNode* root;

/**
 * Insert a new TypeBucket into a binary tree.
 *
 * This organizes the buckets based on the span of their memory since it will
 * never overlap from bucket to bucket
 *
 * This is a normal binary, and could be optimaized later. Possibly an AVL tree?
 */
void insertBucket(TypeBucket* bucket)
{
    //make the new node, because it has to go somewhere
    BucketNode* newNode = cast(BucketNode*)salloc(BucketNode.sizeof);
    newNode.bucket = bucket;
    newNode.left = null;
    newNode.right = null;

    if(root is null)
    {
        root = newNode;
        return;
    }

    BucketNode* current = root;

    while(true)
    {
        //we can assume that the memory spans do not overlap, so if we don't
        //traverse to the left, we much traverse to the right.
        if(bucket.memory < current.bucket.memory)
        {
            if(current.left is null)
            {
                current.left = newNode;
                return;
            }

            current = current.left;
        }
        else
        {
            if(current.right is null)
            {
                current.right = newNode;
                return;
            }

            current = current.right;
        }
    }

    assert(0);//we should never end up here!
}


TypeBucket* findBucket(void* ptr)
{
    //check if the pointer is in the boundaries of the heap memory
    if(ptr < memBot || ptr >= memTop)
        return null;

    BucketNode* current = root;
    while(current !is null)
    {
        if(current.bucket.contains(ptr))
            return current.bucket;

        current = (ptr < current.bucket.memory)? current.left:current.right;
    }

    return null;
}

