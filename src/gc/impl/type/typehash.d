//fast searching of type information for allocations
module gc.impl.type.typehash;
import gc.impl.type.typemanager;
import core.internal.spinlock;

import cstdlib = core.stdc.stdlib : malloc, free;


size_t max(size_t a, size_t b) nothrow @nogc
{
    return (a>b)?a:b;
}

enum hashSize = 191;
enum instanceBlock = 256;

import core.stdc.stdio;

struct TypeHash
{
    auto mutex = shared(AlignedSpinLock)(SpinLock.Contention.brief);
    TypeManager[hashSize+1] hashArray;
    void* hashMemory;
    void* nextManagerPos;

    void initialize() nothrow
    {
        auto arrayManagerSize = __traits(classInstanceSize,ArrayManager);
        auto objectManagerSize = __traits(classInstanceSize,ObjectManager);
        auto rawManagerSize = __traits(classInstanceSize,RawManager);

        size_t largestTypeManager  = max(max(rawManagerSize, objectManagerSize), arrayManagerSize);



        if(largestTypeManager > instanceBlock)
         {
             auto breakpoint = 0;
         }

        //get enough memory for all types
        hashMemory = cstdlib.malloc(instanceBlock*(hashSize+1));
        nextManagerPos = hashMemory;

        //put the raw manager in the last index
        hashArray[hashSize] = newManager!RawManager(hashSize);
    }

    ~this()
    {
        foreach(manager; hashArray)
        {
            if(manager !is null)
                destroy(manager);
        }

        cstdlib.free(hashMemory);
    }

    T newManager(T, Args...)(auto ref Args args) nothrow @nogc
    {
        import core.stdc.string: memcpy;

        // Get some memory and bump the pointer
        auto ptr = nextManagerPos;
        nextManagerPos += instanceBlock;

        //get the default initializer and copy it to the memory address
        auto init = typeid(T).initializer();
        memcpy(ptr, init.ptr, init.length);

        //call the constructor
        (cast(T)ptr).__ctor(args);

        //return the new class instance
        return cast(T)ptr;
    }

    //compute the primary hash
    uint primaryHash(size_t key) const nothrow @nogc
    {
        return key%hashSize;
    }

    //compute the secondary hash
    uint secondaryHash(size_t key) const nothrow @nogc
    {
        return 1 + ((key/hashSize)%(hashSize-1));
    }

    /**
     * Search by type to find the manager for this type
     */
    TypeManager getTypeManager(size_t size, const TypeInfo ti) nothrow @nogc
    {
        if(ti !is null)
        {
            mutex.lock();
            scope(exit) mutex.unlock();

            //use the address of the type info as the key
            size_t key = cast(size_t)(cast(void*)(ti));

            auto pos = primaryHash(key);
            auto offset = secondaryHash(key);

            while(true)
            {
                //auto pos = hashFunc(key, attempts);

                if(hashArray[pos] is null)
                {
                    //casting is expensive, should add a member to TypeInfo
                    hashArray[pos] = (cast(TypeInfo_Array) ti is null)?
                                     newManager!ObjectManager(size, ti, pos):
                                     newManager!ArrayManager(ti, pos);

                    return (hashArray[pos]);
                }
                else if (hashArray[pos].info is ti)
                    return hashArray[pos];

                //recalulate the hash
                pos = (pos+offset)%hashSize;
            }
        }

        //return the raw memory manager
        return hashArray[hashSize];
    }

    TypeManager opIndex(int index) nothrow @nogc
    {

        if(index < 0)
            return null;

        mutex.lock();
        scope(exit) mutex.unlock();

        return hashArray[index];
    }

    int opApply(int delegate(TypeManager) nothrow dg ) nothrow
    {
        int result = 0;

        for(int i = 0; i < hashArray.length; ++i)
        {
            if(hashArray[i] !is null)
                result = dg(hashArray[i]);

            if(result)
                break;
        }

        return result;
    }
}


unittest
{
    import gc.impl.type.memory;

    class TestClass
    {
        int testMember;
    }

    auto intInfo = typeid(int);
    auto testInfo = typeid(TestClass);

    GCAllocator allocator;
    allocator.initialize();
    TypeManager.allocator = &allocator;


    TypeHash typeHash;
    typeHash.initialize();

    auto managerOne = typeHash.getTypeManager(int.sizeof, intInfo);
    auto managerTwo = typeHash.getTypeManager(int.sizeof, intInfo);

    assert(managerOne !is null, "Got a null manager");
    assert(managerTwo !is null, "Got a null manager");

    assert(managerOne is managerTwo, "Got a different manager!");
    assert(cast(ObjectManager)managerOne !is null, "Manager was the wrong type!");

    auto managerThree = typeHash.getTypeManager(__traits(classInstanceSize, TestClass), testInfo);

    assert(managerThree !is null, "Got a null manager");

    auto managerFour = typeHash.getTypeManager(16, null);

    assert(managerFour !is null, "Got a null manager");

}

