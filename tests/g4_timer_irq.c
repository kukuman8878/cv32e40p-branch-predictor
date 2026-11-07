/*
 * Directed test (item ⑩): timer interrupt while branch predictor is active.
 *
 * Uses the example_tb timer peripheral (available under Verilator, unlike the
 * random-interrupt generator). Enables mstatus.MIE + mie.MTIE, arms the timer,
 * then runs a branch-heavy loop so an interrupt lands in the middle of active
 * prediction. The interrupt redirect (PC_EXCEPTION) must take priority over any
 * pending prediction (~pc_set gating) and execution must resume correctly.
 *
 * A dedicated vector table (g4_irq_vectors.S) installs a timer handler at
 * vector slot 7. The handler increments irq_hits and returns via mret.
 *
 * Self-check: irq_hits > 0 and the loop's checksum is exact. EN=0 vs EN=1 must
 * both PASS with identical sums/hits.
 */

#include <stdio.h>
#include <stdlib.h>

volatile unsigned int irq_hits = 0;

#define TIMER_MASK_REG 0x15000000u
#define TIMER_VAL_REG  0x15000004u

int main(void)
{
    volatile unsigned int sum = 0;

    __asm__ volatile ("csrsi mstatus, 0x8");
    __asm__ volatile ("csrrs zero, mie, %0" :: "r"(0x80));

    *(volatile unsigned int *)TIMER_MASK_REG = 0x80u;
    *(volatile unsigned int *)TIMER_VAL_REG = 2500u;

    for (int i = 0; i < 4000; i++) {
        if (i & 1) sum += (unsigned int)i;
        else sum -= (unsigned int)i;
    }

    unsigned int hits = irq_hits;
    *(volatile unsigned int *)TIMER_MASK_REG = 0u;
    __asm__ volatile ("csrrc zero, mie, %0" :: "r"(0x80));
    __asm__ volatile ("csrci mstatus, 0x8");

    int expect = 0;
    for (int i = 0; i < 4000; i++)
        expect += (i & 1) ? i : -i;

    printf("g4_timer_irq hits=%u sum=%u expect=%d\n", hits, sum, expect);

    if (hits == 0)        return 1;
    if ((int)sum != expect) return 2;
    return EXIT_SUCCESS;
}
