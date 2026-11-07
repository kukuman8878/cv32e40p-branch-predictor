#!/bin/bash
# Performance/CPI + stall+flush directed test + register-level consistency.
#
#   ./scripts/g5_full.sh
#
# 1) fresh-build EN=0 / EN=1 Verilator models (with the tb stall-injection
#    fixes in riscv_gnt_stall.sv / riscv_rvalid_stall.sv)
# 2) compile g5_stall_flush (stall+flush) and g5_consistency (register-level signature)
# 3) run g5_stall_flush on both models with +stall_observe (observation point)
# 4) run g5_consistency on both, diff the 64-word (memory+GPR) signature
# 5) re-run the 5 baseline benchmarks on both models, capturing cycle + retired
#    instruction count (minstret) + branch stats -> g5_cycle_cpi.csv
#
# Exit code 0 iff every check passes. Logs/CSVs land under project/metrics/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$PROJECT_DIR/tests"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$METRICS_DIR/logs"
SIMBUILD_EN0="${SIMBUILD_EN0:-$PROJECT_DIR/sim_build}"
SIMBUILD_EN1="${SIMBUILD_EN1:-$PROJECT_DIR/sim_build_en1}"

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
BTB_ENTRIES="${BTB_ENTRIES:-32}"

mkdir -p "$LOGS_DIR"

# ---- environment snapshot ----
{
  echo "--- environment snapshot ---"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uname: $(uname -a)"
  echo "gcc: $(${RISCV_PREFIX}gcc --version | head -1)"
  echo "objcopy: $(${RISCV_PREFIX}objcopy --version | head -1)"
  echo "verilator: $(verilator --version 2>/dev/null | head -1)"
  echo "yosys: $(yosys --version 2>/dev/null | head -1)"
  echo "repo commit: $(git -C "$PROJECT_DIR/../cv32e40p" rev-parse HEAD 2>/dev/null)"
  echo "branch: $(git -C "$PROJECT_DIR/../cv32e40p" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "base: b353438ff469c030c89f6804f3b24a2852880e8b"
  echo "BHT_DEPTH=$BHT_DEPTH BTB_ENTRIES=$BTB_ENTRIES ARCH=$ARCH OPT=$OPT"
  echo "maxcycles=$MAXCYCLES"
  echo "spike: $(which spike 2>/dev/null || echo 'NOT INSTALLED (skipped, documented)')"
} > "$LOGS_DIR/g5_environment.txt"

# ---- build ----
echo "== build EN=0 =="
OUTDIR="$SIMBUILD_EN0" "$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/g5_en0_build.log" 2>&1
echo "== build EN=1 =="
BR_PREDICT_EN=1 BHT_DEPTH="$BHT_DEPTH" BTB_ENTRIES="$BTB_ENTRIES" \
  OUTDIR="$SIMBUILD_EN1" "$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/g5_en1_build.log" 2>&1
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
    -o "$out/$name.elf" 2> "$LOGS_DIR/g5_${name}_compile.log"
  ${RISCV_PREFIX}objcopy -O verilog "$out/$name.elf" "$out/$name.hex"
  echo "  compiled $name -> $out/$name.hex"
}

echo "== compile tests =="
compile_one g5_stall_flush  vectors.S       g5_stall_flush.c
compile_one g5_consistency  vectors.S       g5_consistency.c g5_dump_gprs.S

# ---- run helper ----
run_one() {
  local model="$1"; local name="$2"; shift 2
  local hex="$METRICS_DIR/$name/$name.hex"
  local log="$LOGS_DIR/g5_${model}_${name}_run.log"
  local bin="$SIMBUILD_EN0/obj_dir/Vtb_top"
  [ "$model" = "en1" ] && bin="$SIMBUILD_EN1/obj_dir/Vtb_top"
  "$bin" "+firmware=$hex" "+maxcycles=$MAXCYCLES" "$@" > "$log" 2>&1
  RUN_RC=$?
  RUN_LOG="$log"
}

parse_bpred() {
  grep -oE 'branch_total=[0-9]+ pred_taken=[0-9]+ correct=[0-9]+ mispredict=[0-9]+' "$1" | tail -1 || echo ""
}

overall=0

# ---- stall+flush same-cycle test ----
echo "== stall+flush directed test =="
STALL_CSV="$METRICS_DIR/g5_stall_flush.csv"
{
  echo "model,rc,result,cycles,minstret,branch_total,pred_taken,correct,mispredict,stall_active,stall_flush_coincide,stall_mispredict_coincide"
} > "$STALL_CSV"
for model in en0 en1; do
  run_one "$model" g5_stall_flush +stall_observe
  rc=$RUN_RC; log=$RUN_LOG
  r=$([ -n "$(grep 'EXIT SUCCESS' "$log")" ] && echo PASS || echo FAIL)
  cyc=$(grep -oE 'cycle_count = [0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo n/a)
  mst=$(grep -oE 'minstret=[0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo n/a)
  bt=$(grep -oE 'branch_total=[0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  pt=$(grep -oE 'pred_taken=[0-9]+'   "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  co=$(grep -oE 'correct=[0-9]+'      "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  mi=$(grep -oE 'mispredict=[0-9]+'   "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  sa=$(grep -oE 'stall_active=[0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  sf=$(grep -oE 'stall_flush_coincide=[0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  sm=$(grep -oE 'stall_mispredict_coincide=[0-9]+' "$log" | grep -oE '[0-9]+' | tail -1 || echo 0)
  echo "$model,$rc,$r,$cyc,$mst,$bt,$pt,$co,$mi,$sa,$sf,$sm" >> "$STALL_CSV"
  if [ "$r" != "PASS" ]; then overall=1; fi
  echo "  $model: $r rc=$rc cyc=$cyc minstret=$mst stall_active=$sa stall+flush=$sf stall+mispredict=$sm"
done

EN1_MIS=$(grep '^en1,' "$STALL_CSV" | cut -d, -f9)
EN1_SF=$(grep '^en1,' "$STALL_CSV" | cut -d, -f11)
EN1_SM=$(grep '^en1,' "$STALL_CSV" | cut -d, -f12)
if [ "${EN1_MIS:-0}" -gt 0 ]; then
  echo "  [ASSERT] EN=1 mispredictions>0: OK ($EN1_MIS)"
else
  echo "  [ASSERT] EN=1 mispredictions>0: FAIL"; overall=1
fi
if [ "${EN1_SM:-0}" -gt 0 ]; then
  echo "  [ASSERT] EN=1 stall+mispredict-flush co-occurred: OK ($EN1_SM)"
else
  echo "  [ASSERT] EN=1 stall+mispredict-flush co-occurred: FAIL"; overall=1
fi
if [ "${EN1_SF:-0}" -gt 0 ]; then
  echo "  [ASSERT] EN=1 stall+redirect co-occurred: OK ($EN1_SF)"
else
  echo "  [ASSERT] EN=1 stall+redirect co-occurred: FAIL"; overall=1
fi

# ---- register-level consistency (memory + GPR signature) ----
echo "== register-level consistency (memory + GPR signature) =="
run_one en0 g5_consistency +signature="$LOGS_DIR/g5_en0_consistency.sig"
sig0_rc=$RUN_RC
run_one en1 g5_consistency +signature="$LOGS_DIR/g5_en1_consistency.sig"
sig1_rc=$RUN_RC
CONSIST="PASS"
if [ "$sig0_rc" != "0" ] || [ "$sig1_rc" != "0" ]; then CONSIST="FAIL(rc)"; fi
if [ -f "$LOGS_DIR/g5_en0_consistency.sig" ] && [ -f "$LOGS_DIR/g5_en1_consistency.sig" ]; then
  w0=$(wc -l < "$LOGS_DIR/g5_en0_consistency.sig")
  w1=$(wc -l < "$LOGS_DIR/g5_en1_consistency.sig")
  if ! diff -q "$LOGS_DIR/g5_en0_consistency.sig" "$LOGS_DIR/g5_en1_consistency.sig" > /dev/null; then
    CONSIST="FAIL(diff)"
    diff "$LOGS_DIR/g5_en0_consistency.sig" "$LOGS_DIR/g5_en1_consistency.sig" > "$LOGS_DIR/g5_consistency_diff.log" 2>&1 || true
  else
    echo "  signature identical (EN0 == EN1, $w0 words incl. GPR dump)" > "$LOGS_DIR/g5_consistency_diff.log"
  fi
else
  CONSIST="FAIL(no sig file)"
fi
[ "$CONSIST" = "PASS" ] || overall=1
echo "  consistency: $CONSIST (en0_rc=$sig0_rc en1_rc=$sig1_rc, words=$w0/$w1)"

# ---- performance / CPI (5 benchmarks, cycle + minstret) ----
echo "== performance / CPI =="
CPI_CSV="$METRICS_DIR/g5_cycle_cpi.csv"
{
  echo "program,en0_cycles,en0_minstret,en0_cpi,en1_cycles,en1_minstret,en1_cpi,branch_total,pred_taken,correct,mispredict,direction_acc_pct,speedup_pct"
} > "$CPI_CSV"

for name in hello_world fib branch_heavy mixed low_branch; do
  run_one en0 "$name"; rc0=$RUN_RC; log0=$RUN_LOG
  run_one en1 "$name"; rc1=$RUN_RC; log1=$RUN_LOG
  r0=$([ -n "$(grep 'EXIT SUCCESS' "$log0")" ] && echo PASS || echo FAIL)
  r1=$([ -n "$(grep 'EXIT SUCCESS' "$log1")" ] && echo PASS || echo FAIL)
  c0=$(grep -oE 'cycle_count = [0-9]+' "$log0" | grep -oE '[0-9]+' | tail -1 || echo 0)
  c1=$(grep -oE 'cycle_count = [0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  m0=$(grep -oE 'minstret=[0-9]+' "$log0" | grep -oE '[0-9]+' | tail -1 || echo 0)
  m1=$(grep -oE 'minstret=[0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  bt=$(grep -oE 'branch_total=[0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  pt=$(grep -oE 'pred_taken=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  co=$(grep -oE 'correct=[0-9]+'      "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  mi=$(grep -oE 'mispredict=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo 0)
  cpi0="n/a"; cpi1="n/a"
  [ "$m0" != "0" ] && cpi0=$(awk "BEGIN { printf \"%.4f\", $c0 / $m0 }")
  [ "$m1" != "0" ] && cpi1=$(awk "BEGIN { printf \"%.4f\", $c1 / $m1 }")
  acc="n/a"
  [ "$bt" != "0" ] && acc=$(awk "BEGIN { printf \"%.2f\", 100.0 * $co / $bt }")
  spd="n/a"
  [ "$c0" != "0" ] && spd=$(awk "BEGIN { printf \"%.2f\", 100.0 * ($c0 - $c1) / $c0 }")
  echo "$name,$c0,$m0,$cpi0,$c1,$m1,$cpi1,$bt,$pt,$co,$mi,$acc,$spd" >> "$CPI_CSV"
  if [ "$r0" != "PASS" ] || [ "$r1" != "PASS" ]; then overall=1; fi
  echo "  $name: EN0=$r0($c0 cyc/$m0 inst) EN1=$r1($c1 cyc/$m1 inst) speedup=${spd}% acc=${acc}%"
done

# ---- summary ----
echo
echo "================ FULL SUMMARY ================"
echo "stall+flush:"
cat "$STALL_CSV"
echo
echo "consistency: $CONSIST"
echo "performance/CPI:"
cat "$CPI_CSV"
echo "overall: $([ $overall -eq 0 ] && echo PASS || echo FAIL)"
echo "logs: $LOGS_DIR (g5_*)"
echo "================================================="

exit $overall
