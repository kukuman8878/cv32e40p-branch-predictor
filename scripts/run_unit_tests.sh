#!/bin/bash
# G2 unit tests: lint + build + run the BHT/BTB predictor modules in isolation.
#
#   ./scripts/run_unit_tests.sh
#
# Steps:
#   1) verilator --lint-only -Wall on cv32e40p_bht.sv and cv32e40p_btb.sv
#   2) verilator --binary each self-contained testbench and run it
#   3) print a summary table (lint errors/warnings, test PASS/FAIL, exit codes)
#
# Exit code 0  => all lint 0-error AND all tests PASS.
# Exit code 1  => any lint error or any test failure.
#
# Logs land under project/metrics/logs/ with prefixes g2_bht_ / g2_btb_.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${REPO_DIR:-$PROJECT_DIR/../cv32e40p}"
RTL="$REPO_DIR/rtl"
UNIT="$PROJECT_DIR/tests/unit"
LOGS="$PROJECT_DIR/metrics/logs"
BUILD="$PROJECT_DIR/sim_build/unit"

mkdir -p "$LOGS" "$BUILD"

VERILATOR="${VERILATOR:-verilator}"
VER="$(verilator --version 2>/dev/null | head -1)"

BUILD_FLAGS="--binary --timing -Wall -Wno-fatal \
  -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH \
  -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-UNUSEDGENVAR -Wno-CASEINCOMPLETE"

declare -A LINT_RC TEST_RC

{
  echo "--- G2 unit-test environment snapshot ---"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uname: $(uname -a)"
  echo "verilator: $VER"
} > "$LOGS/g2_environment.txt"

verilator --lint-only -Wall \
  "$RTL/cv32e40p_bht.sv" --top-module cv32e40p_bht \
  > "$LOGS/g2_bht_lint.log" 2>&1
LINT_RC[bht]=$?

verilator --lint-only -Wall \
  "$RTL/cv32e40p_btb.sv" --top-module cv32e40p_btb \
  > "$LOGS/g2_btb_lint.log" 2>&1
LINT_RC[btb]=$?

verilator $BUILD_FLAGS \
  "$RTL/cv32e40p_bht.sv" "$UNIT/tb_bht.sv" \
  --top-module tb_bht --Mdir "$BUILD/bht_obj" -o Vtb_bht \
  > "$LOGS/g2_bht_build.log" 2>&1
if [ $? -eq 0 ]; then
  "$BUILD/bht_obj/Vtb_bht" > "$LOGS/g2_bht_run.log" 2>&1
  TEST_RC[bht]=$?
else
  echo "BHT build failed (see g2_bht_build.log)"
  TEST_RC[bht]=1
fi

verilator $BUILD_FLAGS \
  "$RTL/cv32e40p_btb.sv" "$UNIT/tb_btb.sv" \
  --top-module tb_btb --Mdir "$BUILD/btb_obj" -o Vtb_btb \
  > "$LOGS/g2_btb_build.log" 2>&1
if [ $? -eq 0 ]; then
  "$BUILD/btb_obj/Vtb_btb" > "$LOGS/g2_btb_run.log" 2>&1
  TEST_RC[btb]=$?
else
  echo "BTB build failed (see g2_btb_build.log)"
  TEST_RC[btb]=1
fi

echo
echo "========================== G2 UNIT TEST SUMMARY =========================="
printf "%-6s %-10s %-10s %-10s\n" "module" "lint" "test" "test_rc"
for m in bht btb; do
  lstr="err(${LINT_RC[$m]})"
  tstr=$([ "${TEST_RC[$m]:-1}" -eq 0 ] && echo "PASS" || echo "FAIL")
  printf "%-6s %-10s %-10s %-10s\n" "$m" "$lstr" "$tstr" "${TEST_RC[$m]:-1}"
done
echo "verilator: $VER"
echo "logs:      $LOGS (g2_*_lint.log / g2_*_build.log / g2_*_run.log)"
echo "=========================================================================="

overall=0
for m in bht btb; do
  [ "${LINT_RC[$m]:-1}" -ne 0 ] && overall=1
  [ "${TEST_RC[$m]:-1}" -ne 0 ] && overall=1
done
exit $overall
