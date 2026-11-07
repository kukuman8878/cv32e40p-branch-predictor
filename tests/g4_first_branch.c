/*
 * Directed test (item ③): first-time (cold) branch prediction.
 *
 * On a cold start the BHT resets to WNT (predict not-taken) and the BTB is
 * empty, so the very first conditional branch must be a BTB miss. The branch
 * is then re-executed to show warm-up. Correctness is self-checked; cold vs
 * warm behaviour is visible in the EN=1 [BPRED] stats.
 */

#include <stdio.h>
#include <stdlib.h>

static int first_branch(int x)
{
    if (x > 5)
        return x * 2;
    return x;
}

int main(void)
{
    volatile int r0 = first_branch(10);
    volatile int r1 = first_branch(3);
    volatile int r2 = first_branch(10);

    printf("g4_first_branch r0=%d r1=%d r2=%d\n", r0, r1, r2);
    if (r0 != 20 || r1 != 3 || r2 != 20)
        return 1;
    return EXIT_SUCCESS;
}
