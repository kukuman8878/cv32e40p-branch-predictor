/*
 * Baseline benchmark: mixed workload (computation + branching).
 *
 * Recursive Fibonacci + a branch/arithmetic loop. A mix of function calls
 * (jal/jalr), conditional branches (recursion base case) and integer
 * arithmetic. Self-checking against known values.
 *
 * Compiled with the same crt0/link.ld/syscalls framework and flags as
 * hello_world (rv32imc). No functional RTL is modified.
 */

#include <stdio.h>
#include <stdlib.h>

static int fib(int n)
{
    if (n < 2)
        return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void)
{
    volatile unsigned int acc = 0;

    /* fib(20) == 6765; fib(24) == 46368 */
    int f20 = fib(20);
    int f24 = fib(24);
    if (f20 != 6765 || f24 != 46368)
        return 1;

    /* mixed loop: branch + arithmetic */
    for (int i = 1; i <= 100; i++) {
        if (i % 3 == 0)
            acc += i * 2;
        else if (i % 2 == 0)
            acc += i;
        else
            acc += i * 3;
    }

    printf("mixed fib24=%d acc=%u\n", f24, acc);

    if (f24 != 46368)
        return 1;
    return EXIT_SUCCESS;
}
