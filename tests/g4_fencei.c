/*
 * Directed test (item ⑩): fence.i redirect path (PC_FENCEI).
 *
 * Executes fence.i between branch-heavy loops. fence.i forces the controller
 * into its FENCEI state and redirects the prefetcher to pc_id+4; it must not
 * corrupt the predictor state or subsequent execution. Self-checked.
 */

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    volatile unsigned int sum = 0;

    for (int i = 0; i < 100; i++) {
        if (i & 1) sum += i; else sum -= i;
    }

    __asm__ volatile ("fence.i");

    for (int i = 100; i < 200; i++) {
        if (i & 1) sum += i; else sum -= i;
    }

    int expect = 0;
    for (int i = 0; i < 200; i++)
        expect += (i & 1) ? i : -i;

    printf("g4_fencei sum=%u expect=%d\n", sum, expect);
    if ((int)sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
