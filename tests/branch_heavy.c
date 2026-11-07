/*
 * Baseline benchmark: branch-heavy workload.
 *
 * Quicksort + branch-dense classification/scan loops. Designed to maximise
 * the number of conditional branches (comparisons, loop back-edges) so the
 * BHT/BTB predictor has the most to gain. Self-checking: computes a checksum,
 * prints it, and exits 0 on success.
 *
 * Compiled with the same crt0/link.ld/syscalls framework and flags as
 * hello_world (rv32imc). No functional RTL is modified.
 */

#include <stdio.h>
#include <stdlib.h>

#define N 64

static int data[N];
static volatile unsigned int g_sum = 0;

static void swap(int *a, int *b)
{
    int t = *a;
    *a = *b;
    *b = t;
}

/* classic Lomuto quicksort: branch-dense (partition + recursive calls) */
static void quicksort(int lo, int hi)
{
    if (lo >= hi)
        return;
    int pivot = data[hi];
    int i = lo - 1;
    for (int j = lo; j < hi; j++) {
        if (data[j] < pivot) {
            i++;
            swap(&data[i], &data[j]);
        }
    }
    swap(&data[i + 1], &data[hi]);
    int p = i + 1;
    quicksort(lo, p - 1);
    quicksort(p + 1, hi);
}

/* branch-dense scan: many if/else chains over the sorted data */
static void classify_scan(void)
{
    for (int i = 0; i < N; i++) {
        int v = data[i];
        if (v < 100) {
            if (v < 50) {
                if (v < 25)
                    g_sum += v + 1;
                else
                    g_sum += v + 2;
            } else {
                g_sum += v + 3;
            }
        } else if (v < 200) {
            if (v < 150)
                g_sum += v + 4;
            else
                g_sum += v + 5;
        } else {
            if (v < 250)
                g_sum += v + 6;
            else
                g_sum += v + 7;
        }
    }
}

int main(void)
{
    /* deterministic pseudo-random fill (LCG) */
    unsigned int seed = 12345;
    for (int i = 0; i < N; i++) {
        seed = seed * 1664525u + 1013904223u;
        data[i] = (int)(seed >> 24); /* 0..255 */
    }

    quicksort(0, N - 1);

    /* verify sorted */
    for (int i = 1; i < N; i++) {
        if (data[i - 1] > data[i])
            return 1;
    }

    classify_scan();

    /* checksum over sorted data + scan sum */
    unsigned int ck = 0;
    for (int i = 0; i < N; i++)
        ck = ck * 31u + (unsigned int)data[i];

    printf("branch_heavy checksum=%u sum=%u\n", ck, g_sum);

    if (ck == 0u)
        return 1; /* should never happen with real data */
    return EXIT_SUCCESS;
}
