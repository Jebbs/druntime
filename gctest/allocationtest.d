module main;

import core.stdc.stdio;

import core.memory;

import core.time;

void main()
{


    for(int i = 0; i < 1_000; i++)
        auto intPtr = new int();

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

