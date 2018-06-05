module main;

import core.stdc.stdio;

import core.memory;

import core.time;

import core.thread;

void main()
{

    //test 1
    {
    auto thr = Thread.getThis();
    immutable prio = thr.priority;
    scope (exit) thr.priority = prio;

    assert(prio == Thread.PRIORITY_DEFAULT);
    assert(prio >= Thread.PRIORITY_MIN && prio <= Thread.PRIORITY_MAX);
    thr.priority = Thread.PRIORITY_MIN;
    assert(thr.priority == Thread.PRIORITY_MIN);
    thr.priority = Thread.PRIORITY_MAX;
    assert(thr.priority == Thread.PRIORITY_MAX);
    }

    //test 2
    {
    import core.sync.semaphore;

    auto thr = new Thread({});
    thr.start();
    Thread.sleep(1.msecs);       // wait a little so the thread likely has finished
    thr.priority = Thread.PRIORITY_MAX; // setting priority doesn't cause error
    auto prio = thr.priority;    // getting priority doesn't cause error
    assert(prio >= Thread.PRIORITY_MIN && prio <= Thread.PRIORITY_MAX);
    }

    //test 3
    {
        auto t1 = new Thread({
            foreach (_; 0 .. 20)
                Thread.getAll;
        }).start;
        auto t2 = new Thread({
            foreach (_; 0 .. 20)
                GC.collect;
        }).start;
        t1.join();
        t2.join();
    }


    /*
    //Static array slice: no capacity
    int[4] sarray = [1, 2, 3, 4];
    int[]  slice  = sarray[];
    assert(sarray.capacity == 0);
    //Appending to slice will reallocate to a new array
    slice ~= 5;
    assert(slice.capacity >= 5);

    auto arr = new int[5];
    auto sizey = GC.sizeOf(arr.ptr);

    //Dynamic array slices
    int[] a = [1, 2, 3, 4];
    auto sz = GC.sizeOf(a.ptr);
    int[] b = a[1 .. $];
    int[] c = a[1 .. $ - 1];

    //auto sz = GC.sizeOf(a.ptr);

    printf("array size: %d\n", a.length);
    printf("array capacity: %d\n", a.capacity);
    printf("array memory size: %d\n", GC.sizeOf(a.ptr));


    debug(SENTINEL) {} else // non-zero capacity very much depends on the array and GC implementation
    {
        assert(a.capacity != 0);
        assert(a.capacity == b.capacity + 1); //both a and b share the same tail
    }
    assert(c.capacity == 0);              //an append to c must relocate c.
    */
    /*
    for(int i = 0; i < 100000; i++)
    {
        if(i == 1024)
        {
            int breaker = 0;
        }
        auto intPtr = new int();
    }
    */
    /*

    auto start = MonoTime.currTime().ticks;
    GC.collect();
    auto end = MonoTime.currTime().ticks;
    printf("The collection took: %d nanoseconds\n", ticksToNSecs(end-start));

    /*
    auto coolArray = new STest[12];

/*
    abstract class C
    {
       void func();
       void func(int a);
       int func(int a, int b);
    }

    alias functionTypes = typeof(__traits(getVirtualFunctions, C, "func"));
    assert(typeid(functionTypes[0]).toString() == "void function()");
    assert(typeid(functionTypes[1]).toString() == "void function(int)");
    assert(typeid(functionTypes[2]).toString() == "int function(int, int)");
    */

    /*
    auto start = MonoTime.currTime().ticks;

    auto coolArray = new Test[12];
    //auto test = new int();

    auto end = MonoTime.currTime().ticks;

    printf("The allocation took: %d nanoseconds\n", ticksToNSecs(end-start));

    void** arrayLoc = cast(void**)&coolArray;
    printf("array location on stack: %X\n", arrayLoc);
    printf("array location on heap: %X\n", cast(void*)(*(&coolArray)));

    printf("array length: %d\n", coolArray.length);
    printf("array capacity: %d\n", coolArray.capacity);

    /*
    void* top = &coolArray[1];
    void* bot = &coolArray[0];

    auto diff = top - bot;

    printf("size of each array element: %u\n", diff);

    start = MonoTime.currTime().ticks;

    //auto coolArray = new Test[12];
    auto test2 = new int();

    end = MonoTime.currTime().ticks;

    printf("The allocation took: %d nanoseconds\n", ticksToNSecs(end-start));


    printf("array size: %d\n", GC.sizeOf(cast(void*)(*(&coolArray))));

    start = MonoTime.currTime().ticks;
    auto coolerArray = new STest[12];
    end = MonoTime.currTime().ticks;
    printf("The allocation took: %d nanoseconds\n", ticksToNSecs(end-start));


    printf("array2 length: %d\n", coolerArray.length);
    printf("array2 capacity: %d\n", coolerArray.capacity);

    top = &coolerArray[1];
    bot = &coolerArray[0];

    diff = top - bot;

    printf("size of each array element: %u\n", diff);

    start = MonoTime.currTime().ticks;
    int* test = new int();
    end = MonoTime.currTime().ticks;
    printf("The allocation took: %d nanoseconds\n", ticksToNSecs(end-start));

    printf("%d\n", *test);

    *test = 100;
    printf("0x%X\n", test);
    printf("%d\n", *test);

    start = MonoTime.currTime().ticks;
    test = new int(200);
    end = MonoTime.currTime().ticks;
    printf("The allocation took: %d nanoseconds\n", ticksToNSecs(end-start));

    printf("0x%X\n", test);
    printf("%d\n", *test);

    start = MonoTime.currTime().ticks;
    void* rawMemory = GC.malloc(200);//, GC.BlkAttr.APPENDABLE);
    end = MonoTime.currTime().ticks;
    printf("The allocation took: %d nanoseconds\n", ticksToNSecs(end-start));

    test = new int(200);
    */

    /*
    for(int i = 0; i < 50; ++i)
    {
        auto test = new STest(i);
    }
    /*
    auto test = new STest();
    printf("Address on stack: %X\n", &test);
    test = new STest();
    printf("Address on stack: %X\n", &test);
    test = new STest();
    printf("Address on stack: %X\n", &test);
    */

    /*
    auto start = MonoTime.currTime().ticks;
    GC.collect();
    auto end = MonoTime.currTime().ticks;
    printf("The collection took: %d nanoseconds\n", ticksToNSecs(end-start));

    //auto test = new int();

    string testString = "what";
    testString ~= "?!\0";

    printf("%s\n", testString.ptr);
    */

}


class Test
{
    int thing1;
    int* thing2;
    int thing3;
}

struct STest
{
    int thing1;
    int* thing2;
    int thing3;
    int thing4;
    int thing5;
    int thing6;

    this(int i)
    {
        thing1 = i;
    }
    ~this()
    {
        printf("Running destructor for object %d\n", thing1);
    }
}

