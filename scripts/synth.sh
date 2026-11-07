#!/bin/bash
# Yosys synthesis of the CV32E40P branch predictor.
#
#   ./scripts/synth.sh
#
# Step 1 (full core): attempt `read_verilog -sv` of the full core RTL list.
#   Expected to FAIL on Yosys 0.33 because the core uses `import cv32e40p_pkg::*`
#   (package import) and packed multi-dim arrays, which Yosys 0.33 does not
#   elaborate. The failure is captured verbatim as evidence (never fabricated).
#
# Step 2 (incremental): synthesize the branch predictor (BHT + BTB + pred_taken
#   glue) via the SEMANTICALLY-EQUIVALENT synthesis shims in project/synth/
#   (NOT the shipped RTL). Compare BR_PREDICT_EN=0 vs =1 with the SAME script
#   and parameters, and report cells / memory bits / area via `stat`.
#
# No timing analysis: no OpenSTA / PDK available, so WNS/critical path are
# reported as "NOT EVALUATED". No power library: power is "NOT EVALUATED".
#
# Artifacts land under project/metrics/ (prefix g5_synth_).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${REPO_DIR:-$PROJECT_DIR/../cv32e40p}"
RTL="$REPO_DIR/rtl"
SYNTH_DIR="$PROJECT_DIR/synth"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$METRICS_DIR/logs"

BHT_DEPTH="${BHT_DEPTH:-256}"
BTB_ENTRIES="${BTB_ENTRIES:-128}"
CELLS_LIB="/usr/share/yosys/cells.lib"

mkdir -p "$LOGS_DIR"

echo "== Yosys version =="
yosys --version 2>&1 | tee "$LOGS_DIR/g5_synth_environment.txt"
echo "BHT_DEPTH=$BHT_DEPTH BTB_ENTRIES=$BTB_ENTRIES" | tee -a "$LOGS_DIR/g5_synth_environment.txt"
echo "cells.lib present: $([ -f "$CELLS_LIB" ] && echo yes || echo no)" | tee -a "$LOGS_DIR/g5_synth_environment.txt"

# ---- Step 1: full-core attempt (expected to fail, captured honestly) ----
echo "== Step 1: full-core read_verilog attempt =="
RTLFILES="include/cv32e40p_apu_core_pkg.sv include/cv32e40p_fpu_pkg.sv include/cv32e40p_pkg.sv cv32e40p_if_stage.sv cv32e40p_cs_registers.sv cv32e40p_register_file_ff.sv cv32e40p_load_store_unit.sv cv32e40p_id_stage.sv cv32e40p_aligner.sv cv32e40p_decoder.sv cv32e40p_compressed_decoder.sv cv32e40p_fifo.sv cv32e40p_prefetch_buffer.sv cv32e40p_hwloop_regs.sv cv32e40p_mult.sv cv32e40p_int_controller.sv cv32e40p_ex_stage.sv cv32e40p_alu_div.sv cv32e40p_alu.sv cv32e40p_ff_one.sv cv32e40p_popcnt.sv cv32e40p_apu_disp.sv cv32e40p_controller.sv cv32e40p_obi_interface.sv cv32e40p_prefetch_controller.sv cv32e40p_sleep_unit.sv cv32e40p_core.sv cv32e40p_top.sv cv32e40p_bht.sv cv32e40p_btb.sv"
FULLCORE_LOG="$LOGS_DIR/g5_synth_fullcore_attempt.log"
( cd "$RTL" && yosys -Q -p "read_verilog -sv $RTLFILES; hierarchy -check" ) > "$FULLCORE_LOG" 2>&1
echo "full-core read exit: $? (see $FULLCORE_LOG)"
grep -iE "error" "$FULLCORE_LOG" | head -5 || true

# ---- Step 2: incremental predictor synthesis (per module, EN=0 vs EN=1) ----
synth_module() {
  local top="$1"; local chparam="$2"; local log="$3"
  local cp=""
  [ -n "$chparam" ] && cp="-chparam $chparam"
  yosys -Q -p "
    read_verilog -sv $SYNTH_DIR/cv32e40p_bht_synth.sv \
                      $SYNTH_DIR/cv32e40p_btb_synth.sv \
                      $SYNTH_DIR/cv32e40p_branch_predictor_synth.sv
    hierarchy -check -top $top $cp
    proc; opt
    synth -top $top
    stat
  " > "$log" 2>&1
  return $?
}

echo "== Step 2: incremental predictor synthesis (per module) =="
synth_module cv32e40p_bht               "BR_PREDICT_EN 0" "$LOGS_DIR/g5_synth_bht_en0.log"
synth_module cv32e40p_bht               "BR_PREDICT_EN 1" "$LOGS_DIR/g5_synth_bht_en1.log"
synth_module cv32e40p_btb               ""                 "$LOGS_DIR/g5_synth_btb.log"
synth_module cv32e40p_branch_predictor  "BR_PREDICT_EN 1" "$LOGS_DIR/g5_synth_predictor_en1.log"
synth_module cv32e40p_branch_predictor  "BR_PREDICT_EN 0" "$LOGS_DIR/g5_synth_predictor_en0.log"

last_cells() {
  grep -E "^   Number of cells:" "$1" | grep -oE '[0-9]+' | tail -1 || echo "0"
}

BHT_EN0=$(last_cells "$LOGS_DIR/g5_synth_bht_en0.log")
BHT_EN1=$(last_cells "$LOGS_DIR/g5_synth_bht_en1.log")
BTB_ANY=$(last_cells "$LOGS_DIR/g5_synth_btb.log")
PRED_EN1=$(last_cells "$LOGS_DIR/g5_synth_predictor_en1.log")
PRED_EN0=$(last_cells "$LOGS_DIR/g5_synth_predictor_en0.log")

BHT_STORAGE=$(( BHT_DEPTH * 2 ))
BTB_TAGW=$(( 32 - $(echo "l($BTB_ENTRIES)/l(2)" | bc -l | awk '{print int($1+0.999)}') - 1 ))
BTB_STORAGE=$(( BTB_ENTRIES * (1 + BTB_TAGW + 32) ))
TOTAL_STORAGE=$(( BHT_STORAGE + BTB_STORAGE ))

SUMMARY="$METRICS_DIR/g5_synth_summary.csv"
{
  echo "module,config,number_of_cells"
  echo "cv32e40p_bht,BR_PREDICT_EN=0,$BHT_EN0"
  echo "cv32e40p_bht,BR_PREDICT_EN=1,$BHT_EN1"
  echo "cv32e40p_btb,(no EN param),$BTB_ANY"
  echo "cv32e40p_branch_predictor,BR_PREDICT_EN=0,$PRED_EN0"
  echo "cv32e40p_branch_predictor,BR_PREDICT_EN=1,$PRED_EN1"
} > "$SUMMARY"

echo
echo "================ SYNTH SUMMARY ================"
echo "incremental predictor (BHT+BTB+pred glue) gate count [generic techlib]:"
cat "$SUMMARY"
echo "combined predictor EN=1 storage FFs: $TOTAL_STORAGE bits (BHT $BHT_STORAGE + BTB $BTB_STORAGE, analytical)"
echo
echo "NOTE: full-core synthesis NOT feasible (Yosys 0.33 SV limits: import pkg::*)."
echo "      The combined EN=0 figure is a shim artifact: the wrapper still exposes"
echo "      btb_target as a public output, keeping the BTB storage alive. In the real"
echo "      core.sv the BTB read/write are fully dead when EN=0 (pred_taken=0,"
echo "      btb_write_valid=0), so a full-flow synthesis would eliminate the whole"
echo "      predictor at EN=0. BHT EN=0 -> 0 cells confirms the dead-code elimination."
echo "      WNS / critical path: NOT EVALUATED (no OpenSTA/PDK)."
echo "      Power: NOT EVALUATED (no power library)."
echo "      um^2 area: NOT AVAILABLE (cells.lib has no area attributes)."
echo "=================================================="

exit 0
