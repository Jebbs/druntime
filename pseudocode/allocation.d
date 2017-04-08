module allocation;

import core.thread;

import core.stdc.stdio;

struct TypeBucket
{
    bool isFull()
    {
        return false;
    }
}

struct TypeStorage
{
    struct TypeNode
    {
        TypeBucket* bucket;
        TypeNode* next;
    }

    TypeInfo info;

    TypeNode* buckets;
    TypeNode* bucketsEnd;
    TypeNode* allocateBucket;

}


uint hashSize = 101; //approx 50 unique data TypeStorage, assume that is enough

TypeStorage[] hashArray;

void hashInit()
{
    import core.stdc.string: memset;

    void* memory; //given some memory

    hashArray = memory[0 .. hashSize];

    memset(memory, 0, hashSize*TypeStorage.sizeof);

}

size_t hashFunc(size_t hash, uint i) nothrow
{
    return ((hash%hashSize) + i*(hash % 7))%hashSize;
}

/**
 *
 */
TypeBucket* getBucket(size_t size, const TypeInfo ti)
{
    uint attempts = 0;

    size_t hash = ti.toHash();

    TypeStorage* storage;

    while(true)
    {
        auto pos = hashFunc(hash, attempts);

        if(hashArray[pos].info is null)
        {
            
            //create a new storage and bucket, and return it
        }
        else if(hashArray[pos].info is ti)
        {
            //check if top bucket is full

            //if it is, create a new one and return that

            //if it isn't then just return
            return hashArray[pos].allocateBucket;
        }

        attempts++;
    }


}



