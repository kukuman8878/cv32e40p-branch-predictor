/*
 * Directed test (item ④): all-not-taken conditional branches.
 *
 * A loop whose body contains only forward branches that are never taken.
 * The BHT for these branches should stay at / decay toward strongly-not-taken
 * (SNT=00) and never produce a taken prediction. Correctness is self-checked.
 */

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    volatile int flag = 0;
    volatile unsigned int sum = 0;

    for (int i = 0; i < 300; i++) {
        if (flag)
            sum += 0xdeadbeefu;
        if (i > 1000000)
            sum += 0x12345678u;
        if (flag && i < 0)
            sum += 0xabcdef01u;
        sum += i;
    }

    unsigned int expect = 300u * 299u / 2u;
    printf("g4_nottaken sum=%u expect=%u\n", sum, expect);
    if (sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
