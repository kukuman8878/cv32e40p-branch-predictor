#!/bin/bash
# Branch-predictor integration verification.
#
# Builds and runs the CV32E40P + example_tb model twice:
#   EN=0  (BR_PREDICT_EN=0, default) -> must be cycle-identical to baseline
#   EN=1  (BR_PREDICT_EN=1)          -> functional correctness + prediction stats
#
# Outputs:
#   metrics/logs/g3_en0_<name>_run.log
#   metrics/logs/g3_en1_<name>_run.log
#   metrics/g3_cycle_comparison.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$METRICS_DIR/logs"
SIMBUILD_EN0="$PROJECT_DIR/sim_build"
SIMBUILD_EN1="$PROJECT_DIR/sim_build_en1"

PROGS="hello_world fib branch_heavy mixed low_branch"
MAXCYCLES="${MAXCYCLES:-5000000}"
BHT_DEPTH="${BHT_DEPTH:-256}"
BTB_ENTRIES="${BTB_ENTRIES:-128}"

mkdir -p "$LOGS_DIR"

echo "== build EN=0 =="
OUTDIR="$SIMBUILD_EN0" "$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/g3_en0_build.log" 2>&1
echo "EN=0 build OK"

echo "== build EN=1 (BHT_DEPTH=$BHT_DEPTH BTB_ENTRIES=$BTB_ENTRIES) =="
BR_PREDICT_EN=1 BHT_DEPTH="$BHT_DEPTH" BTB_ENTRIES="$BTB_ENTRIES" \
  OUTDIR="$SIMBUILD_EN1" "$SCRIPT_DIR/build_tb.sh" > "$LOGS_DIR/g3_en1_build.log" 2>&1
echo "EN=1 build OK"

CSV="$METRICS_DIR/g3_cycle_comparison.csv"
{
  echo "program,en0_cycles,en0_result,en1_cycles,en1_result,en1_branch_total,en1_pred_taken,en1_correct,en1_mispredict,accuracy_pct"
} > "$CSV"

for name in $PROGS; do
  hex="$METRICS_DIR/$name/$name.hex"

  log0="$LOGS_DIR/g3_en0_${name}_run.log"
  "$SIMBUILD_EN0/obj_dir/Vtb_top" "+firmware=$hex" "+maxcycles=$MAXCYCLES" > "$log0" 2>&1 || true
  c0=$(grep -oE 'cycle_count = [0-9]+' "$log0" | grep -oE '[0-9]+' | tail -1 || echo "n/a")
  r0=$([ -n "$(grep 'EXIT SUCCESS' "$log0")" ] && echo PASS || echo FAIL)

  log1="$LOGS_DIR/g3_en1_${name}_run.log"
  "$SIMBUILD_EN1/obj_dir/Vtb_top" "+firmware=$hex" "+maxcycles=$MAXCYCLES" > "$log1" 2>&1 || true
  c1=$(grep -oE 'cycle_count = [0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo "n/a")
  r1=$([ -n "$(grep 'EXIT SUCCESS' "$log1")" ] && echo PASS || echo FAIL)

  bt=$(grep -oE 'branch_total=[0-9]+' "$log1" | grep -oE '[0-9]+' | tail -1 || echo "0")
  pt=$(grep -oE 'pred_taken=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo "0")
  co=$(grep -oE 'correct=[0-9]+'      "$log1" | grep -oE '[0-9]+' | tail -1 || echo "0")
  mi=$(grep -oE 'mispredict=[0-9]+'   "$log1" | grep -oE '[0-9]+' | tail -1 || echo "0")
  if [ "$bt" != "0" ]; then
    acc=$(awk "BEGIN { printf \"%.2f\", 100.0 * $co / $bt }")
  else
    acc="n/a"
  fi

  echo "$name,$c0,$r0,$c1,$r1,$bt,$pt,$co,$mi,$acc" >> "$CSV"
  echo "done $name: EN0=$c0/$r0  EN1=$c1/$r1 (acc=${acc}%)"
done

echo
echo "===== VERIFY SUMMARY ====="
cat "$CSV"
echo "===== logs: $LOGS_DIR ====="
