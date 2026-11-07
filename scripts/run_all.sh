#!/bin/bash
# G6 engineering delivery: one-command end-to-end reproduction.
#
#   ./scripts/run_all.sh
#
# Chains the four stage scripts in the order they depend on each other, then
# emits a single consolidated summary:
#
#   stage 1  reproduce.sh        G1 baseline: compile 5 firmware + build EN=0
#                                + run 5 benchmarks (generates *.hex used later)
#   stage 2  g3_verify.sh        EN=0 / EN=1 functional regression (5 benchmarks
#                                on both models, cycle comparison)
#   stage 3  run_unit_tests.sh   G2 BHT/BTB lint + self-checking unit tests
#   stage 4  synth_full.sh       G5 full-core synthesis BASE / EN=0 / EN=1
#                                (sv2v + Yosys) + cell-count summary CSV
#
# Exit code 0 iff every stage exits 0 AND the key result artifacts are present
# with no "FAIL" marker. Partial results are kept on disk even if a later stage
# fails (a stage's artifacts are not deleted between runs).
#
# No rtl/*.sv is modified. All artifacts land under project/metrics/,
# project/sim_build*/ and project/synth/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
METRICS_DIR="$PROJECT_DIR/metrics"

START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -A STAGE_RC
STAGE_NAMES=(reproduce g3_verify unit_tests synth_full)

run_stage() {
  local name="$1"; shift
  local ts0 ts1
  ts0=$(date +%s)
  echo
  echo "########################################################################"
  echo "## STAGE: $name  ($(date -u +%H:%M:%SZ))"
  echo "########################################################################"
  set +e
  "$@" 
  STAGE_RC[$name]=$?
  set -e
  ts1=$(date +%s)
  echo "## STAGE: $name -> exit ${STAGE_RC[$name]}  ($((ts1-ts0))s)"
}

overall=0

run_stage reproduce "$SCRIPT_DIR/reproduce.sh"
[ "${STAGE_RC[reproduce]}" -eq 0 ] || overall=1

run_stage g3_verify "$SCRIPT_DIR/g3_verify.sh"
[ "${STAGE_RC[g3_verify]}" -eq 0 ] || overall=1

run_stage unit_tests "$SCRIPT_DIR/run_unit_tests.sh"
[ "${STAGE_RC[unit_tests]}" -eq 0 ] || overall=1

run_stage synth_full "$SCRIPT_DIR/synth_full.sh"
[ "${STAGE_RC[synth_full]}" -eq 0 ] || overall=1

G3_CSV="$METRICS_DIR/g3_cycle_comparison.csv"
SYNTH_CSV="$METRICS_DIR/g5r2_synth_full_cells.csv"

echo
echo "########################################################################"
echo "## CONSOLIDATED SUMMARY  (started $START_TS)"
echo "########################################################################"

printf "%-14s %s\n" "stage" "exit"
for s in "${STAGE_NAMES[@]}"; do
  printf "%-14s %s\n" "$s" "${STAGE_RC[$s]:-n/a}"
done

echo
echo "--- EN0/EN1 functional regression (g3_cycle_comparison.csv) ---"
if [ -f "$G3_CSV" ]; then
  cat "$G3_CSV"
  if grep -q "FAIL" "$G3_CSV"; then
    echo ">> regression contains FAIL marker"
    overall=1
  else
    echo ">> all 5 benchmarks PASS on EN0 and EN1"
  fi
else
  echo ">> MISSING: $G3_CSV"
  overall=1
fi

echo
echo "--- unit tests ---"
for m in bht btb; do
  runlog="$METRICS_DIR/logs/g2_${m}_run.log"
  if [ -f "$runlog" ] && grep -q "PASS" "$runlog"; then
    echo "  $m: PASS ($runlog)"
  else
    echo "  $m: FAIL/MISSING"
    overall=1
  fi
done

echo
echo "--- full-core synthesis (g5r2_synth_full_cells.csv) ---"
if [ -f "$SYNTH_CSV" ]; then
  cat "$SYNTH_CSV"
  for key in "base_cells" "en0_cells" "en1_cells" "base_vs_en1_area_growth_pct"; do
    if ! grep -q "$key" "$SYNTH_CSV"; then
      echo ">> MISSING key: $key"
      overall=1
    fi
  done
else
  echo ">> MISSING: $SYNTH_CSV"
  overall=1
fi

echo
echo "########################################################################"
if [ "$overall" -eq 0 ]; then
  echo "## RESULT: ALL STAGES PASS (exit 0)"
else
  echo "## RESULT: ONE OR MORE STAGES FAILED"
fi
echo "## logs:      $METRICS_DIR/logs/"
echo "## summaries: $METRICS_DIR/*.csv"
echo "## finished:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "########################################################################"

exit "$overall"
