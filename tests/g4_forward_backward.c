/*
 * Directed test (item ⑤): forward and backward branches.
 *
 * Backward branches (loop back-edges) and forward branches (conditional skip)
 * are mixed. The predictor must handle both directions of the sign-extended
 * PC-relative offset. Self-checked.
 */

#include <stdio.h>
#include <stdlib.h>

static int clamp(int v)
{
    if (v > 100)
        return 100;
    if (v < 0)
        return 0;
    return v;
}

int main(void)
{
    volatile unsigned int sum = 0;
    int i = 0;

    do {
        int c = clamp(i - 50);
        sum += (unsigned int)c;
        i++;
    } while (i < 256);

    unsigned int expect = 0;
    for (int k = 0; k < 256; k++) {
        int v = k - 50;
        if (v > 100) v = 100;
        if (v < 0) v = 0;
        expect += (unsigned int)v;
    }

    printf("g4_forward_backward sum=%u expect=%u\n", sum, expect);
    if (sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
