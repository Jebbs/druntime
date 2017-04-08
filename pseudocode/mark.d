void* memoryMin, memoryMax;
int* findBucket(void* p)
{
    return null;
}

struct ScanRange
{
    void* pbot, ptop; //the astrisk is left associative, these are both pointers
    size_t pointerMap;

    int opApply(int delegate(void*) dg)
    {
        int result = 0;

        void** memBot = cast(void**)pbot;
        void** memTop = cast(void**)ptop;


        if(pointerMap == size_t.max)
        {
            for(; memBot < memTop; memBot++)
            {
                result = dg(*memBot);

                if(result)
                    break;
            }
        }
        else
        {
            for(auto pos = bsf(pointerMap); pointerMap != 0; pointerMap &= ~(1 << pos))
            {
                result = dg(*(memBot+pos));

                if(result)
                    break;
            }
        }

        return result;
    }

}



struct ScanStack
{
    void* memory;
    size_t count = 0;
    StackRange[] array;

    this(size_t size)
    {
        //allocate size amount of memory and and set up array
    }
    ~this()
    {
        //free memory used by array
    }

    bool empty()
    {
        return count == 0;
    }

    //assume check for empty was done before this was called
    StackRange pop()
    {
        return array[count--];
    }

    void push(StackRange range)
    {
        array[++count] = range;
    }
}


ScanStack scanStack;


void mark(void* memBot, void* memTop)
{
    scanStack.push(ScanRange(memBot, memTop, size_t.max));

    while(!scanStack.empty())
    {
        ScanRange range = scanStack.pop();

        foreach(void* ptr; range)
        {
            if( ptr >= memoryMin && ptr < memoryMax)
            {
                auto bucket = findBucket(ptr);

                if(bucket is null)
                    continue;

                if(!bucket.testMarkAndSet(ptr))
                {
                    if(bucket.getAttr(ptr) & BlkAttr.NO_SCAN)
                        continue;

                    scanStack.push(ptr, bucket.objectSize, bucket.pointerMap);
                }
            }
        }
    }

}

