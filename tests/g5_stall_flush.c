/*
 * Directed test (item ⑦): instruction-fetch stall + redirect/mispredict flush
 * in the SAME cycle.
 *
 * Enables the example_tb deterministic instruction grant stall (STANDARD mode,
 * fixed delay) via the rnd_stall register block at 0x1600xxxx, then runs an
 * alternating taken/not-taken loop that defeats the 2-bit BHT (many
 * mispredictions on EN=1) while every instruction fetch is delayed by the grant
 * stall. The tb_top observation point (gated by +stall_observe) counts cycles
 * where an active grant stall coincides with a redirect (pc_set) and, on EN=1,
 * with a mispredict flush (branch_mispredict).
 *
 * The result is self-checked against a closed form.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define RND_STALL_BASE 0x16000000u

static void rnd_stall_write(unsigned int idx, unsigned int val)
{
    *(volatile unsigned int *)(RND_STALL_BASE + idx * 4u) = val;
}

int main(void)
{
    volatile unsigned int sum = 0;
    const int n = 1024;

    rnd_stall_write(8, 2);
    rnd_stall_write(2, 1);
    rnd_stall_write(0, 1);

    for (int i = 0; i < n; i++) {
        if (i & 1)
            sum += (unsigned int)i;
        else
            sum += (unsigned int)i * 3u;
    }

    rnd_stall_write(0, 0);

    unsigned int ev = 0, od = 0;
    for (int i = 0; i < n; i++) {
        if (i & 1) od += (unsigned int)i;
        else ev += (unsigned int)i;
    }
    unsigned int expect = ev * 3u + od;

    printf("g5_stall_flush sum=%u expect=%u\n", sum, expect);
    if (sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
