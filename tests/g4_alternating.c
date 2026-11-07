/*
 * Directed test (item ④): alternating taken / not-taken branches.
 *
 * A branch that toggles every iteration (i & 1) defeats a naive direction
 * predictor (2-bit saturating counter oscillates between WT and WNT). The
 * result must still be architecturally correct. Self-checked against a known
 * closed form.
 */

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    volatile unsigned int sum = 0;
    const int n = 512;

    for (int i = 0; i < n; i++) {
        if (i & 1)          /* alternates taken / not-taken */
            sum += i;       /* odd indices */
        else
            sum += i * 3u;  /* even indices */
    }

    unsigned int ev = 0, od = 0;
    for (int i = 0; i < n; i++) {
        if (i & 1) od += (unsigned)i;
        else ev += (unsigned)i;
    }
    unsigned int expect = ev * 3u + od;

    printf("g4_alternating sum=%u expect=%u\n", sum, expect);
    if (sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
