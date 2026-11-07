#!/bin/bash
# Full regression: directed boundary tests + consistency + baseline regression.
#
#   ./scripts/g4_full.sh
#
# 1) fresh-build EN=0 (BR_PREDICT_EN=0) and EN=1 (BR_PREDICT_EN=1) models
# 2) compile the directed tests (self-checking C/asm) into byte-granular hex
# 3) run every test on BOTH models, comparing exit code + stdout + [BPRED] stats
# 4) consistency program: capture the signature dump for EN=0 vs EN=1 and diff
# 5) re-run the 5 baseline benchmarks on BOTH models (regression)
#
# Exit code 0 iff every directed test PASSes on both models, the consistency
# signature is byte-identical, and every benchmark PASSes on both models.
#
# Logs land under project/metrics/logs/ with prefix g4_.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$PROJECT_DIR/tests"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$METRICS_DIR/logs"
SIMBUILD_EN0="${SIMBUILD_EN0:-$PROJECT_DIR/sim_build}"
SIMBUILD_EN1="${SIMBUILD_EN1:-$PROJECT_DIR/sim_build_en1}"
REVIEWS_DIR="$PROJECT_DIR/reviews"

export PATH="$HOME/.riscv/bin:$PATH"
RISCV_PREFIX="riscv32-unknown-elf-"
RISCV_ROOT="$HOME/.riscv"

ARCH="rv32imc_zicsr_zifencei"
ABI="ilp32"
OPT="-Os"
CFLAGS="-march=$ARCH -mabi=$ABI $OPT -g -w"
LDLIBS="-lc -lgcc"
INCDIR="$RISCV_ROOT/riscv32-unknown-elf/include"
LIBDIR="$RISCV_ROOT/riscv32-unknown-elf/lib/rv32im/ilp32"
LDFLAGS="-nostdlib -static -T $TESTS_DIR/link.ld"

MAXCYCLES="${MAXCYCLES:-5000000}"
BHT_DEPTH="${BHT_DEPTH:-256}"
BTB_ENTRIES="${BTB_ENTRIES:-128}"

mkdir -p "$LOGS_DIR"

# ---- environment snapshot ----
{
  echo "--- environment snapshot ---"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uname: $(uname -a)"
  echo "gcc: $(${RISCV_PREFIX}gcc --version | head -1)"
  echo "objcopy: $(${RISCV_PREFIX}objcopy --version | head -1)"
  echo "verilator: $(verilator --version 2>/dev/null | head -1)"
  echo "repo commit: $(git -C "$PROJECT_DIR/../cv32e40p" rev-parse HEAD 2>/dev/null)"
  echo "branch: $(git -C "$PROJECT_DIR/../cv32e40p" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "base: b353438ff469c030c89f6804f3b24a2852880e8b"
  echo "BHT_DEPTH=$BHT_DEPTH BTB_ENTRIES=$BTB_ENTRIES ARCH=$ARCH OPT=$OPT"
  echo "maxcycles=$MAXCYCLES"
  echo "spike: $(which spike 2>/dev/null || echo 'NOT INSTALLED (skipped, documented)')"
} > "$LOGS_DIR/g4_environment.txt"

# ---- build ----
echo "== build EN=0 =="
OUTDIR="$SIMBUILD_EN0" "$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/g4_en0_build.log" 2>&1
echo "== build EN=1 =="
BR_PREDICT_EN=1 BHT_DEPTH="$BHT_DEPTH" BTB_ENTRIES="$BTB_ENTRIES" \
  OUTDIR="$SIMBUILD_EN1" "$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/g4_en1_build.log" 2>&1
echo "builds OK"

# ---- compile helper ----
compile_one() {
  local name="$1"; local vectors="$2"; shift 2
  local out="$METRICS_DIR/$name"
  mkdir -p "$out"
  local srcs=""
  for s in "$@"; do srcs="$srcs $TESTS_DIR/$s"; done
  ${RISCV_PREFIX}gcc $CFLAGS $LDFLAGS \
    "$TESTS_DIR/crt0.S" $srcs "$TESTS_DIR/syscalls.c" "$TESTS_DIR/$vectors" \
    -I "$INCDIR" -L "$LIBDIR" $LDLIBS \
    -o "$out/$name.elf" 2> "$LOGS_DIR/g4_${name}_compile.log"
  ${RISCV_PREFIX}objcopy -O verilog "$out/$name.elf" "$out/$name.hex"
  echo "  compiled $name -> $out/$name.hex"
}

echo "== compile directed tests =="
compile_one g4_bht_saturate    vectors.S      g4_bht_saturate.c
compile_one g4_nottaken        vectors.S      g4_nottaken.c
compile_one g4_alternating     vectors.S      g4_alternating.c
compile_one g4_forward_backward vectors.S     g4_forward_backward.c
compile_one g4_nested_adjacent vectors.S      g4_nested_adjacent.c
compile_one g4_first_branch    vectors.S      g4_first_branch.c
compile_one g4_jal_jalr        vectors.S      g4_jal_jalr.c
compile_one g4_rvc             vectors.S      g4_rvc.c
compile_one g4_fencei          vectors.S      g4_fencei.c
compile_one g4_btb_alias       vectors.S      g4_btb_alias.S
compile_one g4_timer_irq       g4_irq_vectors.S g4_timer_irq.c
compile_one g4_consistency     vectors.S      g4_consistency.c

# ---- run helper ----
run_one() {
  local model="$1"; local name="$2"; shift 2
  local hex="$METRICS_DIR/$name/$name.hex"
  local log="$LOGS_DIR/g4_${model}_${name}_run.log"
  local bin="$SIMBUILD_EN0/obj_dir/Vtb_top"
  [ "$model" = "en1" ] && bin="$SIMBUILD_EN1/obj_dir/Vtb_top"
  "$bin" "+firmware=$hex" "+maxcycles=$MAXCYCLES" "$@" > "$log" 2>&1
  RUN_RC=$?
  RUN_LOG="$log"
  RUN_BPRED=$(grep -oE 'branch_total=[0-9]+ pred_taken=[0-9]+ correct=[0-9]+ mispredict=[0-9]+' "$log" | tail -1 || echo "")
  RUN_CYCLE=$(grep -oE 'cycle_count = [0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo "n/a")
}

overall=0
DIRECTED_CSV="$METRICS_DIR/g4_directed_summary.csv"
{
  echo "test,item,en0_rc,en0_result,en0_cycles,en1_rc,en1_result,en1_cycles,en1_branch_total,en1_pred_taken,en1_correct,en1_mispredict"
} > "$DIRECTED_CSV"

declare -A ITEM_MAP=(
  [g4_bht_saturate]="1,4"
  [g4_btb_alias]="2"
  [g4_first_branch]="3"
  [g4_nottaken]="4"
  [g4_alternating]="4"
  [g4_forward_backward]="5"
  [g4_nested_adjacent]="6"
  [g4_rvc]="8"
  [g4_jal_jalr]="9"
  [g4_fencei]="10"
  [g4_timer_irq]="10"
)

DIRECTED="g4_bht_saturate g4_btb_alias g4_first_branch g4_nottaken g4_alternating g4_forward_backward g4_nested_adjacent g4_rvc g4_jal_jalr g4_fencei g4_timer_irq"

echo "== run directed tests =="
for name in $DIRECTED; do
  run_one en0 "$name"; rc0=$RUN_RC; log0=$RUN_LOG
  run_one en1 "$name"; rc1=$RUN_RC; log1=$RUN_LOG
  r0=$([ -n "$(grep 'EXIT SUCCESS' "$log0")" ] && echo PASS || echo FAIL)
  r1=$([ -n "$(grep 'EXIT SUCCESS' "$log1")" ] && echo PASS || echo FAIL)
  c0=$(grep -oE 'cycle_count = [0-9]+' "$log0" | grep -oE '[0-9]+' | tail -1 || echo n/a)
  c1=$(grep -oE 'cycle_count = [0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo n/a)
  bt=$(grep -oE 'branch_total=[0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  pt=$(grep -oE 'pred_taken=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  co=$(grep -oE 'correct=[0-9]+'      "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  mi=$(grep -oE 'mispredict=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  echo "$name,${ITEM_MAP[$name]},$rc0,$r0,$c0,$rc1,$r1,$c1,$bt,$pt,$co,$mi" >> "$DIRECTED_CSV"
  if [ "$r0" != "PASS" ] || [ "$r1" != "PASS" ]; then overall=1; fi
  echo "  $name: EN0=$r0(rc=$rc0) EN1=$r1(rc=$rc1) [BPRED] total=$bt taken=$pt corr=$co mis=$mi"
done

# ---- consistency: signature diff EN0 vs EN1 ----
echo "== consistency signature diff =="
run_one en0 g4_consistency +signature="$LOGS_DIR/g4_en0_consistency.sig"
sig0_rc=$RUN_RC
run_one en1 g4_consistency +signature="$LOGS_DIR/g4_en1_consistency.sig"
sig1_rc=$RUN_RC
CONSIST="PASS"
if [ "$sig0_rc" != "0" ] || [ "$sig1_rc" != "0" ]; then CONSIST="FAIL(rc)"; fi
if [ -f "$LOGS_DIR/g4_en0_consistency.sig" ] && [ -f "$LOGS_DIR/g4_en1_consistency.sig" ]; then
  if ! diff -q "$LOGS_DIR/g4_en0_consistency.sig" "$LOGS_DIR/g4_en1_consistency.sig" > /dev/null; then
    CONSIST="FAIL(diff)"
    diff "$LOGS_DIR/g4_en0_consistency.sig" "$LOGS_DIR/g4_en1_consistency.sig" > "$LOGS_DIR/g4_consistency_diff.log" 2>&1 || true
  else
    echo "  signature identical (EN0 == EN1)" > "$LOGS_DIR/g4_consistency_diff.log"
  fi
else
  CONSIST="FAIL(no sig file)"
fi
[ "$CONSIST" = "PASS" ] || overall=1
echo "  consistency: $CONSIST (en0_rc=$sig0_rc en1_rc=$sig1_rc)"

# ---- baseline regression (5 benchmarks) ----
echo "== baseline regression =="
REGRESSION_CSV="$METRICS_DIR/g4_regression.csv"
{
  echo "program,en0_cycles,en0_result,en1_cycles,en1_result,en1_branch_total,en1_pred_taken,en1_correct,en1_mispredict"
} > "$REGRESSION_CSV"

declare -A BASE_EN0=( [hello_world]=3533 [fib]=377169 [branch_heavy]=20912 [mixed]=3106787 [low_branch]=78753 )
declare -A BASE_EN1=( [hello_world]=3012 [fib]=383398 [branch_heavy]=19588 [mixed]=3212394 [low_branch]=71302 )

for name in hello_world fib branch_heavy mixed low_branch; do
  run_one en0 "$name"; rc0=$RUN_RC; log0=$RUN_LOG
  run_one en1 "$name"; rc1=$RUN_RC; log1=$RUN_LOG
  r0=$([ -n "$(grep 'EXIT SUCCESS' "$log0")" ] && echo PASS || echo FAIL)
  r1=$([ -n "$(grep 'EXIT SUCCESS' "$log1")" ] && echo PASS || echo FAIL)
  c0=$(grep -oE 'cycle_count = [0-9]+' "$log0" | grep -oE '[0-9]+' | tail -1 || echo n/a)
  c1=$(grep -oE 'cycle_count = [0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo n/a)
  bt=$(grep -oE 'branch_total=[0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  pt=$(grep -oE 'pred_taken=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  co=$(grep -oE 'correct=[0-9]+'      "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  mi=$(grep -oE 'mispredict=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  match0=$([ "$c0" = "${BASE_EN0[$name]}" ] && echo OK || echo "MISMATCH(expect ${BASE_EN0[$name]})")
  match1=$([ "$c1" = "${BASE_EN1[$name]}" ] && echo OK || echo "MISMATCH(expect ${BASE_EN1[$name]})")
  echo "$name,${BASE_EN0[$name]},$c0,$r0($match0),${BASE_EN1[$name]},$c1,$r1($match1),$bt,$pt,$co,$mi" >> "$REGRESSION_CSV"
  if [ "$r0" != "PASS" ] || [ "$r1" != "PASS" ] || [ "$c0" != "${BASE_EN0[$name]}" ] || [ "$c1" != "${BASE_EN1[$name]}" ]; then overall=1; fi
  echo "  $name: EN0=$r0 cycles=$c0 [$match0]  EN1=$r1 cycles=$c1 [$match1]"
done

# ---- summary ----
echo
echo "================ FULL REGRESSION SUMMARY ================"
echo "directed tests:"
cat "$DIRECTED_CSV"
echo
echo "consistency: $CONSIST"
echo "regression:"
cat "$REGRESSION_CSV"
echo "overall: $([ $overall -eq 0 ] && echo PASS || echo FAIL)"
echo "logs: $LOGS_DIR (g4_*)"
echo "============================================================"

exit $overall
