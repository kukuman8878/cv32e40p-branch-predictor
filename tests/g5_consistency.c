/*
 * Consistency program (register-level upgrade of g4_consistency).
 *
 * Runs a mix of branch patterns and accumulates checksum words into
 * state[0..31]. Then it dumps the architectural register file x1..x31 into
 * state[32..62] via dump_gprs() and appends a sentinel at state[63].
 *
 * The example_tb signature mechanism then dumps the ENTIRE state[] region.
 * Because the register file is part of the dumped signature, EN=0 vs EN=1 must
 * be byte-identical in BOTH memory and registers — a prediction-induced state
 * corruption in any GPR would be caught.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define SIG_WORDS 32
#define NREGS     31

extern void dump_gprs(volatile uint32_t *buf);

static volatile uint32_t state[SIG_WORDS + NREGS + 1] __attribute__((aligned(16)));

static unsigned int mix(unsigned int x)
{
    unsigned int c = 0;
    for (int i = 0; i < 64; i++) {
        if (i & 1) c = c * 31u + x;
        else c = c ^ (x + i);
        if (c & 1) c += i;
        if (i < 32) c -= (i << 1);
        if (i > 16) c += (i >> 2);
    }
    return c;
}

int main(void)
{
    unsigned int acc = 0x12345678u;

    for (int k = 0; k < SIG_WORDS; k++) {
        acc = mix(acc + (unsigned int)k);
        state[k] = acc;
    }

    for (int r = 0; r < 3; r++) {
        volatile unsigned int s = 0;
        for (int i = 0; i < 200; i++) {
            if (i & 1) s += (unsigned int)i;
            else s -= (unsigned int)i;
        }
        acc = acc * 1103515245u + 12345u + s;
    }

    dump_gprs(&state[32]);
    state[SIG_WORDS + NREGS] = 0xdeadbeefu;

    printf("g5_consistency final_acc=0x%08x\n", acc);

    state[0] = acc;

    volatile unsigned int *begin = (volatile unsigned int *)0x20000008u;
    volatile unsigned int *end   = (volatile unsigned int *)0x2000000Cu;
    volatile unsigned int *dump  = (volatile unsigned int *)0x20000010u;

    *begin = (unsigned int)(uintptr_t)&state[0];
    *end   = (unsigned int)(uintptr_t)&state[SIG_WORDS + NREGS + 1];
    *dump  = 0;

    return EXIT_SUCCESS;
}
