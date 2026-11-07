/*
 * Baseline benchmark: low-branch workload.
 *
 * Straight-line matrix-vector / matrix-matrix arithmetic with very few
 * branches (loop bounds + one final comparison). Designed so the branch
 * predictor has little to gain (mostly fall-through + loop back-edge),
 * providing a "no-benefit" control point against branch-heavy.
 *
 * Compiled with the same crt0/link.ld/syscalls framework and flags as
 * hello_world (rv32imc). No functional RTL is modified.
 */

#include <stdio.h>
#include <stdlib.h>

#define SIZE 16

static int A[SIZE][SIZE];
static int B[SIZE][SIZE];
static int C[SIZE][SIZE];

int main(void)
{
    /* deterministic init */
    int v = 1;
    for (int r = 0; r < SIZE; r++) {
        for (int c = 0; c < SIZE; c++) {
            A[r][c] = v;
            B[r][c] = (v * 3) & 0xffff;
            v = v * 7 + 13;
        }
    }

    /* C = A * B (integer), straight-line inner loops */
    for (int r = 0; r < SIZE; r++) {
        for (int c = 0; c < SIZE; c++) {
            int acc = 0;
            for (int k = 0; k < SIZE; k++)
                acc += A[r][k] * B[k][c];
            C[r][c] = acc;
        }
    }

    /* checksum (single comparison per element, no data-dependent branches) */
    unsigned int ck = 0;
    for (int r = 0; r < SIZE; r++)
        for (int c = 0; c < SIZE; c++)
            ck = (ck * 33u) ^ (unsigned int)C[r][c];

    printf("low_branch checksum=%u\n", ck);

    if (ck == 0u)
        return 1;
    return EXIT_SUCCESS;
}
