module main;

import core.stdc.stdio;

import core.memory;

void main()
{
    int* test = new int();

    *test = 100;

    printf("%X\n", test);

    test = new int(200);
    printf("%X\n", test);

}
