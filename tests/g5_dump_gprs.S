/*
 * Register-file dump helper.
 *
 * void dump_gprs(uint32_t *buf)   // a0 = buf (>= 31 words)
 *
 * Stores x1..x31 into buf[0..30] (buf index = reg number - 1). x0 is
 * architecturally zero and is not stored.
 *
 * x31 (t6) is preserved via the mscratch CSR so that its ORIGINAL value is
 * dumped even though t6 is temporarily clobbered.
 */

.section .text
.global dump_gprs
.type   dump_gprs, @function

dump_gprs:
    csrrw  x31, mscratch, x31
    sw     x1,    0(a0)
    sw     x2,    4(a0)
    sw     x3,    8(a0)
    sw     x4,   12(a0)
    sw     x5,   16(a0)
    sw     x6,   20(a0)
    sw     x7,   24(a0)
    sw     x8,   28(a0)
    sw     x9,   32(a0)
    sw     x10,  36(a0)
    sw     x11,  40(a0)
    sw     x12,  44(a0)
    sw     x13,  48(a0)
    sw     x14,  52(a0)
    sw     x15,  56(a0)
    sw     x16,  60(a0)
    sw     x17,  64(a0)
    sw     x18,  68(a0)
    sw     x19,  72(a0)
    sw     x20,  76(a0)
    sw     x21,  80(a0)
    sw     x22,  84(a0)
    sw     x23,  88(a0)
    sw     x24,  92(a0)
    sw     x25,  96(a0)
    sw     x26, 100(a0)
    sw     x27, 104(a0)
    sw     x28, 108(a0)
    sw     x29, 112(a0)
    sw     x30, 116(a0)
    csrr   x30, mscratch
    sw     x30, 120(a0)
    csrw   mscratch, x31
    ret

.size   dump_gprs, .-dump_gprs
