module main;

import core.stdc.stdio;

import core.memory;

import core.time;

void main()
{

    MonoTime start = MonoTime.currTime;

    auto coolArraySize = __traits(classInstanceSize,Test);

    auto coolArray = new Test[12];

    int* test = new int();



    printf("%d\n", *test);

    *test = 100;

    printf("0x%X\n", test);
    printf("%d\n", *test);

    test = new int(200);
    printf("0x%X\n", test);
    printf("%d\n", *test);

    test = new int(200);




    printf("array length: %d\n", coolArray.length);

    printf("array capacity: %d\n", coolArray.capacity);


    //void* rawMemory = GC.malloc(200);//, GC.BlkAttr.APPENDABLE); //valid?

    Duration duration = MonoTime.currTime - start;

    printf("These allocations took: %d nanoseconds\n", duration.total!("nsecs"));

}


class Test
{
    int thing1;
    int* thing2;
    int thing3;
}