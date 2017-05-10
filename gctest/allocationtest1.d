module main;

import core.stdc.stdio;

import core.memory;

import core.time;

void main()
{

    MonoTime start = MonoTime.currTime;

    auto coolArray = new Test[12];
    Duration duration = MonoTime.currTime - start;

    printf("The allocation took: %d nanoseconds\n", duration.total!("nsecs"));

    void** arrayLoc = cast(void**)&coolArray;

    printf("array location on stack: %X\n", arrayLoc);
    printf("array location on heap: %X\n", *arrayLoc);
    printf("array location on heap: %X\n", cast(void*)(*(&coolArray)));

    printf("array length: %d\n", coolArray.length);
    printf("array capacity: %d\n", coolArray.capacity);

    start = MonoTime.currTime;
    auto coolerArray = new STest[12];
    duration = MonoTime.currTime - start;
    printf("The allocation took: %d nanoseconds\n", duration.total!("nsecs"));


    printf("array2 length: %d\n", coolerArray.length);
    printf("array2 capacity: %d\n", coolerArray.capacity);

    start = MonoTime.currTime;
    int* test = new int();
    duration = MonoTime.currTime - start;
    printf("The allocation took: %d nanoseconds\n", duration.total!("nsecs"));

    printf("%d\n", *test);

    *test = 100;
    printf("0x%X\n", test);
    printf("%d\n", *test);

    start = MonoTime.currTime;
    test = new int(200);
    duration = MonoTime.currTime - start;
    printf("The allocation took: %d nanoseconds\n", duration.total!("nsecs"));

    printf("0x%X\n", test);
    printf("%d\n", *test);

    start = MonoTime.currTime;
    void* rawMemory = GC.malloc(200);//, GC.BlkAttr.APPENDABLE);
    duration = MonoTime.currTime - start;
    printf("The allocation took: %d nanoseconds\n", duration.total!("nsecs")); 

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

