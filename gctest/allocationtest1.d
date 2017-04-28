module main;

import core.stdc.stdio;

import core.memory;

import core.time;

void main()
{

    MonoTime start = MonoTime.currTime;

    auto coolArray = new Test[12];
    printf("array length: %d\n", coolArray.length);
    printf("array capacity: %d\n", coolArray.capacity);

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

}


class Test
{
    int thing1;
    int* thing2;
    int thing3;
}

