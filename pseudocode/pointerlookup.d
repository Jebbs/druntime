struct TypeBucket
{
    void* memory;
    bool contains(void* ptr)
    {
        return false;
    }
}

/**
 * MemoryChunk describes a chunk of memory obtained directly from the OS.
 */
struct MemoryChunk
{
    /// The start of the memory this chunk describes.
    void* start;
    /// The size of the MemoryChunk.
    size_t chunkSize;
    /// Where in the chunk to pop memory from when allocating.
    void* offset;

    /**
     * Grabs some memory from the chunk and advances the offset.
     *
     * Params:
     *  size = The size of the allocation in bytes.
     * Returns:
     *  The location to the start of some memory, or null if not enough space.
     */
    void* allocate(size_t size)
    {
        if(offset+size <= start+ chunkSize)
        {
            void* oldOffset = offset;
            offset += size;
            return oldOffset;
        }

        return null;
    }

}

/// Describes the boundaries of the memory managed by the GC
void* memBot, memTop;

struct BucketNode
{
    TypeBucket* bucket;
    BucketNode* left;
    BucketNode* right;
}

BucketNode* root;


TypeBucket* findBucket(void* ptr)
{

    if(ptr < memBot || ptr >= memTop)
        return null;

    BucketNode* current = root;//root is the start of a bin tree sorted by memory range
    while(current !is null)
    {
        if(current.bucket.contains(ptr))
            return current.bucket;

        current = (ptr < current.bucket.memory)? current.left:current.right;

    }

    return null;
}

//possibly remove the nodes so that memory cound be freed.
//if this is done, put those bad boys into a free list.