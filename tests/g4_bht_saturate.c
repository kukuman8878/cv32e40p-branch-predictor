/*
 * Directed test (item ① / ④): BHT 2-bit saturating-counter saturation.
 *
 * A tight always-taken back-edge loop drives the BHT counter of the loop
 * branch from its reset value (WNT=01) up through WT(10) to ST(11), and a
 * following always-not-taken branch drives it back down. The loop is repeated
 * enough times to guarantee saturation in both directions regardless of the
 * exact initial state. Correctness (the only architecturally visible effect)
 * is self-checked; the counter's 4-state transition itself is verified
 * white-box in the unit tests (tests/unit/tb_bht.sv) and is re-confirmed here
 * only through the EN=1 [BPRED] statistics (pred_taken > 0, mispredict ~ 0
 * after warm-up).
 */

#include <stdio.h>
#include <stdlib.h>

#define ROUNDS 8

int main(void)
{
    volatile unsigned int sum = 0;
    volatile int flag = 1;   /* always-taken forward branch (no early exit) */
    int i;

    for (int r = 0; r < ROUNDS; r++) {
        for (i = 0; i < 200; i++) {
            if (flag)
                sum += i;
            else
                sum += 0xdead0000u;
        }
        flag = 0;
        for (i = 0; i < 200; i++) {
            if (flag)
                sum += 0xbeef0000u;
            else
                sum += i;
        }
        flag = 1;
    }

    unsigned int expect = 39800u * ROUNDS;

    printf("g4_bht_saturate sum=%u expect=%u\n", sum, expect);
    if (sum != expect)
        return 1;
    return EXIT_SUCCESS;
}
