/*
 * Baseline regression program #2 (beyond hello_world): recursive fib.
 * Simple, self-checking, used to prove the Verilator + picolibc flow works
 * for a non-trivial program with function calls and branches.
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
    int r = fib(20); /* 6765 */
    printf("fib(20)=%d\n", r);
    if (r != 6765)
        return 1;
    return EXIT_SUCCESS;
}
