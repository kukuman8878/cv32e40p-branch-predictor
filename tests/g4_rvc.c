/*
 * Directed test (item ⑧): RVC mixed-length code and halfword addresses.
 *
 * Compiled with -march=rv32imc (C extension), so the body contains compressed
 * instructions and branch targets land on 2-byte (halfword) boundaries. The
 * predictor indexes BHT/BTB on PC[INDEX_W:1] (halfword granularity) and must
 * not alias two branches in the same 32-bit word. Self-checked correctness;
 * compressed-instruction presence is additionally confirmed via objdump in the
 * harness log.
 */

#include <stdio.h>
#include <stdlib.h>

static int rvc_loop(int n)
{
    volatile int acc = 0;
    for (int i = 0; i < n; i++) {
        if (i & 1)
            acc += i;
        else
            acc -= i;
    }
    return acc;
}

int main(void)
{
    volatile int r = rvc_loop(300);

    int expect = 0;
    for (int i = 0; i < 300; i++)
        expect += (i & 1) ? i : -i;

    printf("g4_rvc r=%d expect=%d\n", r, expect);
    if (r != expect)
        return 1;
    return EXIT_SUCCESS;
}
