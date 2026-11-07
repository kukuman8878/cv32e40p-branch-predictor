/*
 * Directed test (item ⑨): JAL / JALR must be unaffected by the predictor.
 *
 * Direct calls (JAL), indirect calls through function pointers (JALR), and a
 * computed return are exercised. The predictor must not interfere with jump
 * resolution in ID. Self-checked against known results.
 */

#include <stdio.h>
#include <stdlib.h>

static int add3(int a, int b, int c) { return a + b + c; }
static int sub2(int a, int b) { return a - b; }

typedef int (*binop)(int, int);

static int apply(binop fn, int x, int y)
{
    return fn(x, y);
}

int main(void)
{
    binop table[2];

    int (*f3)(int, int, int) = add3;
    volatile int r0 = f3(1, 2, 3);
    volatile int r1 = add3(10, 20, 30);
    volatile int r2 = sub2(100, 1);

    table[0] = sub2;
    table[1] = (binop)0;
    volatile int r3 = apply(table[0], 50, 8);

    printf("g4_jal_jalr r0=%d r1=%d r2=%d r3=%d\n", r0, r1, r2, r3);
    if (r0 != 6 || r1 != 60 || r2 != 99 || r3 != 42)
        return 1;
    return EXIT_SUCCESS;
}
