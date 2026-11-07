/*
 * Directed test (item ⑥): nested and adjacent conditional branches.
 *
 * Tightly nested if/else and adjacent branches in straight-line code. The
 * predictor sees multiple conditional branches with no intervening non-branch
 * instruction in the fetch stream. Self-checked against a reference model.
 */

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    volatile unsigned int sum = 0;

    for (int i = 0; i < 128; i++) {
        if (i < 32) {
            if (i < 16) {
                if (i < 8)
                    sum += i + 1;
                else
                    sum += i + 2;
            } else {
                if (i < 24)
                    sum += i + 3;
                else
                    sum += i + 4;
            }
        } else {
            if (i < 64) {
                if (i < 48)
                    sum += i + 5;
                else
                    sum += i + 6;
            } else {
                if (i < 96)
                    sum += i + 7;
                else
                    sum += i + 8;
            }
        }
    }

    unsigned int expect = 0;
    for (int i = 0; i < 128; i++) {
        int r;
        if (i < 8) r = i + 1;
        else if (i < 16) r = i + 2;
        else if (i < 24) r = i + 3;
        else if (i < 32) r = i + 4;
        else if (i < 48) r = i + 5;
        else if (i < 64) r = i + 6;
        else if (i < 96) r = i + 7;
        else r = i + 8;
        expect += (unsigned int)r;
    }

    printf("g4_nested_adjacent sum=%u expect=%u\n", sum, expect);
    if (sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
