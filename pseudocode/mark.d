
import core.memory;

//describes the boundaries of the GC managed heap
//these are used when searching for pointers (if not in these bounds, we won't perform a search)
void* memBottom, memTop;

//defined in gc.os module. These are desined to allocate pages at a time.
void *os_mem_map(size_t nbytes) nothrow;
int os_mem_unmap(void *base, size_t nbytes) nothrow;

enum PAGE_SIZE = 4096;//4kb


TypeBucket* findBucket(void* ptr);

struct TypeBucket
{
    void* memory;
    size_t objectSize;
    uint[ObjectsPerBucket] attributes;//the attributes per object

    /**
     * Check if the mark bit is set for this pointer, and set it if not set.
     *
     * This function assumes that the pointer is within this bucket.
     *
     * Returns:
     *  True if the pointer was already marked, false if it wasn't.
     */
    bool testMarkAndSet(void* p) nothrow
    {
        auto pos = (p - memory)/objectSize;

        if(attributes[pos] & BlkAttr.NO_INTERIOR) //check if we can skip interior pointers
        {
            if(p !is memory + pos*objectSize)//check to see if we point to the base or not
            {
                //true implies this data does not need to be scanned.
                //might need to rewrite the documentation to mention this case
                return true;
            }
        }

        uint markBit = 1 << pos;

        if(markMap & markBit)
            return true;

        markMap |= markBit;
        return false;
    }
}

/**
 * ScanRange describes a range of memory that is going to get scanned.
 *
 * It holds a pointer bitmap for the type that spans the range, and will be
 * scanned precisely if possible.
 */
struct ScanRange
{
    void* pbot, ptop; //the astrisk is left associative, these are both pointers
    size_t pointerMap;

    //this allows the ScanRange to be used in a foreach loop
    //the compiler will lower everything efficiently
    int opApply(int delegate(void*) dg)
    {
        int result = 0;

        void** memBot = cast(void**)pbot;
        void** memTop = cast(void**)ptop;


        if(pointerMap == size_t.max) //scan conservatively
        {
            for(; memBot < memTop; memBot++)
            {
                result = dg(*memBot);

                if(result)
                    break;
            }
        }
        else //scan precisely with bsf
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

        assert(size%ScanRange.sizeof == 0);//should always be wholly divisible

        memory = os_mem_map(size);

        array = (cast(ScanRange*)memory)[0 .. (size/ScanRange.sizeof)]; //pretend this is an array of ScanRanges

    }
    ~this()
    {
        //free memory used by array
        os_mem_unmap(memory, array.length*ScanRange.sizeof);
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


//Start the stack at some large size so that we hopefully never run into an overflow
ScanStack scanStack = ScanStack(3*PAGE_SIZE);


/**
 * The mark function will go through the memory range given to it and look for pointers.
 * If any are possibly found, the pointer will be marked as reachable, and the
 * memory it points to will be scanned, and so on.
 */
void mark(void* memBot, void* memTop)
{
    scanStack.push(ScanRange(memBot, memTop, size_t.max)); //push the current range onto the stack to start the algorithm

    while(!scanStack.empty())
    {
        ScanRange range = scanStack.pop();

        foreach(void* ptr; range)
        {
            if( ptr >= memBottom && ptr < memTop)
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

