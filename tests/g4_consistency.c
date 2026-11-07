/*
 * Consistency program: bit-exact architectural-state comparison EN=0 vs EN=1.
 *
 * Runs a mix of branch patterns and accumulates checksum words into a
 * signature array, then uses the example_tb signature mechanism
 * (0x20000008 begin / 0x2000000C end / 0x20000010 dump+exit).
 *
 * The harness captures the signature (via +signature=<file>) for EN=0 and EN=1
 * and diffs them: the two must be byte-identical (same final architectural
 * state). The signature is computed from data-dependent branches so any
 * prediction error would corrupt it.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define SIG_WORDS 32

static volatile unsigned int sig[SIG_WORDS] __attribute__((aligned(16)));

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
        sig[k] = acc;
    }

    for (int r = 0; r < 3; r++) {
        volatile unsigned int s = 0;
        for (int i = 0; i < 200; i++) {
            if (i & 1) s += (unsigned int)i;
            else s -= (unsigned int)i;
        }
        acc = acc * 1103515245u + 12345u + s;
    }

    printf("g4_consistency final_acc=0x%08x\n", acc);

    sig[0] = acc;

    volatile unsigned int *begin = (volatile unsigned int *)0x20000008u;
    volatile unsigned int *end   = (volatile unsigned int *)0x2000000Cu;
    volatile unsigned int *dump  = (volatile unsigned int *)0x20000010u;

    *begin = (unsigned int)(uintptr_t)&sig[0];
    *end   = (unsigned int)(uintptr_t)&sig[SIG_WORDS];
    *dump  = 0;

    return EXIT_SUCCESS;
}
