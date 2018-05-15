module gc.impl.type.scan;

import core.bitop: bsf;

import gc.impl.typed.systemalloc;

/**
 * ScanRange describes a range of memory that is going to get scanned.
 *
 * It holds a pointer bitmap for the type that spans the range, and will be
 * scanned precisely if possible.
 */
struct ScanRange
{
    void* pbot, ptop; //the asterisk is left associative, these are both pointers
    size_t* pointerMap; //pointer to the array of pointer data

    //this allows the ScanRange to be used in a foreach loop
    //the compiler will lower everything efficiently
    int opApply(int delegate(void*) nothrow dg ) nothrow
    {
        debug import core.stdc.stdio;
        int result = 0;

        void** memBot = cast(void**)pbot;
        void** memTop = cast(void**)ptop;

        if(pointerMap == cast(size_t*)1) //scan conservatively
        {
            for(; memBot < memTop; memBot++)
            {
                //debug printf("scanning conservatively: %X -> %X\n", memBot, *memBot);

                result = dg(*memBot);

                if(result)
                    break;
            }
        }
        else //scan precisely with bsf
        {
            auto objectsize = pointerMap[0]/size_t.sizeof;
            pointerMap++;

            static if(size_t.sizeof == 8)
                    size_t mapSize = 64; //64 (bits * pointer size / bytes per pointer because pointer arithmetic)
                else
                    size_t mapSize = 32; //32


            //number of maps that we need to look at
            auto mapCount = objectsize/mapSize + (objectsize%mapSize)?1:0;

            while(memBot<memTop)
            {
                for(int index = 0; index < mapCount; index++)
                {
                    size_t currentMap = pointerMap[index];
                    size_t offset = index*mapSize;
                    while(currentMap)
                    {
                        auto pos = bsf(currentMap);
                        currentMap &= ~(1 << pos);
                        auto mem = memBot+offset+pos;
                        result = dg(*(memBot+offset+pos));
                        if(result)
                        {
                            memBot = memTop;
                            break;
                        }
                    }
                }
                memBot+= objectsize;
            }
        }

        return result;
    }
}

/**
 * ScanStack describes a stack of ScanRange objects.
 *
 * The memory the stack uses is allocated upfront and assumed to be adequate.
 */
struct ScanStack
{
    import core.stdc.stdio;

    void* memory;
    size_t count = 0;
    ScanRange[] array;
    size_t memSize;

    this(size_t size)
    {
        //allocate size amount of memory and set up array

        assert(size%ScanRange.sizeof == 0);//should always be wholly divisible

        memory = os_mem_map(size);
        memSize = size;

        //pretend this is an array of ScanRanges
        array = (cast(ScanRange*)memory)[0 .. (size/ScanRange.sizeof)];
    }

    ~this()
    {
        //free memory used by array
        os_mem_unmap(memory, memSize);
    }

    bool empty() nothrow
    {
        return count == 0;
    }

    //assume check for empty was done before this was called
    ScanRange pop() nothrow
    {
        debug
        {
            //printf("Stack popped: %d elements\n", count-1);
        }
        return array[count--];
    }

    void push(ScanRange range) nothrow
    {
        debug
        {
            //printf("Stack pusheded: %d elements\n", count+1);
        }
        array[++count] = range;
    }
}