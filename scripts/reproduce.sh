#!/bin/bash
# Baseline freeze: one-command reproduction.
#
#   1) compile the 5 firmware images (hello_world, fib, branch_heavy, mixed,
#      low_branch) with a single picolibc-based bare-metal framework,
#   2) convert each ELF to a byte-granular Verilog hex (objcopy -O verilog),
#   3) build the CV32E40P + example_tb Verilator model (read-only RTL),
#   4) run each image, capturing the exit status + cycle count,
#   5) print a summary table.
#
# No rtl/*.sv is modified. All artifacts land under project/metrics/ and
# project/sim_build/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${REPO_DIR:-$PROJECT_DIR/../cv32e40p}"
TESTS_DIR="$PROJECT_DIR/tests"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$METRICS_DIR/logs"
SIMBUILD="$PROJECT_DIR/sim_build"

export PATH="$HOME/.riscv/bin:$PATH"
RISCV_PREFIX="riscv32-unknown-elf-"
RISCV_ROOT="$HOME/.riscv"

# ---- fixed toolchain / options (documented in 03_verification_plan.md) ----
ARCH="rv32imc_zicsr_zifencei"
ABI="ilp32"
OPT="-Os"
CFLAGS="-march=$ARCH -mabi=$ABI $OPT -g -w"
LDLIBS="-lc -lgcc"
INCDIR="$RISCV_ROOT/riscv32-unknown-elf/include"
LIBDIR="$RISCV_ROOT/riscv32-unknown-elf/lib/rv32im/ilp32"
LDFLAGS="-nostdlib -static -T $TESTS_DIR/link.ld"

PROGS="hello_world fib branch_heavy mixed low_branch"

MAXCYCLES="${MAXCYCLES:-5000000}"

mkdir -p "$LOGS_DIR"

# ---- 0) environment snapshot ----
{
  echo "--- reproduce environment snapshot ---"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uname: $(uname -a)"
  echo "gcc: $(${RISCV_PREFIX}gcc --version | head -1)"
  echo "objcopy: $(${RISCV_PREFIX}objcopy --version | head -1)"
  echo "verilator: $(verilator --version 2>/dev/null | head -1)"
  echo "repo commit: $(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
  echo "ARCH=$ARCH ABI=$ABI OPT=$OPT"
  echo "CFLAGS=$CFLAGS"
  echo "LDFLAGS=$LDFLAGS LDLIBS=$LDLIBS"
} > "$LOGS_DIR/environment_g1.txt"

# ---- 1) compile each program ----
for name in $PROGS; do
  out="$METRICS_DIR/$name"
  mkdir -p "$out"
  ${RISCV_PREFIX}gcc $CFLAGS $LDFLAGS \
    "$TESTS_DIR/crt0.S" "$TESTS_DIR/$name.c" "$TESTS_DIR/syscalls.c" \
    "$TESTS_DIR/vectors.S" \
    -I "$INCDIR" -L "$LIBDIR" $LDLIBS \
    -o "$out/$name.elf" 2> "$LOGS_DIR/${name}_compile.log"
  ${RISCV_PREFIX}objcopy -O verilog "$out/$name.elf" "$out/$name.hex"
  echo "compiled $name -> $out/$name.hex ($(wc -l < "$out/$name.hex") hex lines)"
done

# ---- 2) build verilator model (reuse build_tb.sh) ----
"$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/build_tb.log" 2>&1
echo "verilator build OK"

# ---- 3) run each image ----
declare -A CYCLES RESULT
for name in $PROGS; do
  hex="$METRICS_DIR/$name/$name.hex"
  log="$LOGS_DIR/${name}_run.log"
  set +e
  "$SIMBUILD/obj_dir/Vtb_top" "+firmware=$hex" "+maxcycles=$MAXCYCLES" > "$log" 2>&1
  rc=$?
  set -e
  if grep -q "EXIT SUCCESS" "$log"; then
    RESULT[$name]="PASS"
  else
    RESULT[$name]="FAIL"
  fi
  cycle=$(grep -oE 'cycle_count = [0-9]+' "$log" | grep -oE '[0-9]+' | tail -1)
  CYCLES[$name]="${cycle:-n/a}"
  echo "run $name: rc=$rc result=${RESULT[$name]} cycles=${CYCLES[$name]}"
done

# ---- 4) summary ----
echo
echo "=========================== BASELINE SUMMARY ==========================="
printf "%-14s %-8s %-12s %s\n" "program" "result" "cycles" "hex"
for name in $PROGS; do
  printf "%-14s %-8s %-12s %s\n" "$name" "${RESULT[$name]}" "${CYCLES[$name]}" \
    "$METRICS_DIR/$name/$name.hex"
done
echo "=========================================================================="
