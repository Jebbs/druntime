module main;

import core.stdc.stdio;

import core.memory;

import core.time;

void main()
{

    MonoTime start = MonoTime.currTime;

    auto coolArray = new Test[12];

    void** arrayLoc = cast(void**)&coolArray;

    printf("array location on stack: %X\n", arrayLoc);
    printf("array location on heap: %X\n", *arrayLoc);
    printf("array location on heap: %X\n", cast(void*)(*(&coolArray)));

    printf("array length: %d\n", coolArray.length);
    printf("array capacity: %d\n", coolArray.capacity);

    auto coolerArray = new STest[12];
    printf("array2 length: %d\n", coolerArray.length);
    printf("array2 capacity: %d\n", coolerArray.capacity);

    int* test = new int();
    printf("%d\n", *test);

    *test = 100;
    printf("0x%X\n", test);
    printf("%d\n", *test);

    test = new int(200);
    printf("0x%X\n", test);
    printf("%d\n", *test);

    void* rawMemory = GC.malloc(200);//, GC.BlkAttr.APPENDABLE);

    Duration duration = MonoTime.currTime - start;

    printf("These allocations took: %d nanoseconds\n", duration.total!("nsecs"));

    start = MonoTime.currTime;
    GC.collect();
    duration = MonoTime.currTime - start;
    printf("The collection took: %d nanoseconds\n", duration.total!("nsecs"));

    test = new int();

    string testString = "what";
    testString = testString~"?!";
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
}

