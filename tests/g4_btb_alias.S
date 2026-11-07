/*
 * Directed test (item ②): BTB tag hit / conflict / eviction.
 *
 * Two always-taken conditional branches whose PCs are exactly 256 bytes apart
 * (both 256-byte aligned via .balign 256). With BTB_ENTRIES=128 the index is
 * PC[7:1], so a 256-byte (0x100) offset flips only bit 8 -> same index,
 * different tag. In a direct-mapped BTB the two entries therefore evict each
 * other (conflict). Calling them alternately forces write -> evict -> write
 * cycles; correctness must be unaffected (a resolved branch always overrides
 * the prediction). Self-checking: each call returns input+1; a poison
 * instruction is skipped only if the always-taken branch is resolved correctly.
 */

.section .text
.align 2
.option norvc

.balign 256
.globl g4_btb_blk1
.type g4_btb_blk1, @function
g4_btb_blk1:
	beq a0, a0, 1f
	addi a0, a0, 1000
1:
	addi a0, a0, 1
	ret

.balign 256
.globl g4_btb_blk2
.type g4_btb_blk2, @function
g4_btb_blk2:
	beq a0, a0, 1f
	addi a0, a0, 2000
1:
	addi a0, a0, 1
	ret

.section .text
.align 2
.globl main
.type main, @function
main:
	addi sp, sp, -16
	sw ra, 12(sp)

	li a0, 0
	jal g4_btb_blk1
	jal g4_btb_blk2
	jal g4_btb_blk1
	jal g4_btb_blk2
	jal g4_btb_blk1
	jal g4_btb_blk2

	li t0, 6
	beq a0, t0, .Lok
	li a0, 1
	lw ra, 12(sp)
	addi sp, sp, 16
	ret
.Lok:
	li a0, 0
	lw ra, 12(sp)
	addi sp, sp, 16
	ret

.size main, .-main
