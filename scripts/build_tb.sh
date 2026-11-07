#!/bin/bash
# Build the CV32E40P + example_tb Verilator model.
# Reads RTL read-only from the fixed-commit repo, and uses the locally patched
# tb in project/tb/ (parameter renames COREV_PULP/COREV_CLUSTER, clock gate,
# byte-granular firmware load, +verbose-gated monitor, cycle counter).
# No rtl/*.sv is modified.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${REPO_DIR:-$PROJECT_DIR/../cv32e40p}"
RTL="$REPO_DIR/rtl"
BHV="$REPO_DIR/bhv"
TB="$PROJECT_DIR/tb"
OUTDIR="${OUTDIR:-$PROJECT_DIR/sim_build}"
MDIR="$OUTDIR/obj_dir"

mkdir -p "$MDIR"

GFLAGS=""
if [ -n "${BR_PREDICT_EN:-}" ]; then
  GFLAGS="$GFLAGS -GBR_PREDICT_EN=$BR_PREDICT_EN"
fi
if [ -n "${BHT_DEPTH:-}" ]; then
  GFLAGS="$GFLAGS -GBHT_DEPTH=$BHT_DEPTH"
fi
if [ -n "${BTB_ENTRIES:-}" ]; then
  GFLAGS="$GFLAGS -GBTB_ENTRIES=$BTB_ENTRIES"
fi

verilator --binary --timing -Wall -Wno-fatal \
  $GFLAGS \
  -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH -Wno-UNDRIVEN \
  -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNOPTFLAT -Wno-IMPORTSTAR -Wno-ENUMVALUE \
  -I"$RTL/include" -I"$TB/include" -I"$BHV" \
  "$RTL/include/cv32e40p_apu_core_pkg.sv" \
  "$RTL/include/cv32e40p_fpu_pkg.sv" \
  "$RTL/include/cv32e40p_pkg.sv" \
  "$TB/include/perturbation_pkg.sv" \
  "$RTL/cv32e40p_if_stage.sv" \
  "$RTL/cv32e40p_cs_registers.sv" \
  "$RTL/cv32e40p_register_file_ff.sv" \
  "$RTL/cv32e40p_load_store_unit.sv" \
  "$RTL/cv32e40p_id_stage.sv" \
  "$RTL/cv32e40p_aligner.sv" \
  "$RTL/cv32e40p_decoder.sv" \
  "$RTL/cv32e40p_compressed_decoder.sv" \
  "$RTL/cv32e40p_fifo.sv" \
  "$RTL/cv32e40p_prefetch_buffer.sv" \
  "$RTL/cv32e40p_hwloop_regs.sv" \
  "$RTL/cv32e40p_mult.sv" \
  "$RTL/cv32e40p_int_controller.sv" \
  "$RTL/cv32e40p_ex_stage.sv" \
  "$RTL/cv32e40p_alu_div.sv" \
  "$RTL/cv32e40p_alu.sv" \
  "$RTL/cv32e40p_ff_one.sv" \
  "$RTL/cv32e40p_popcnt.sv" \
  "$RTL/cv32e40p_apu_disp.sv" \
  "$RTL/cv32e40p_controller.sv" \
  "$RTL/cv32e40p_obi_interface.sv" \
  "$RTL/cv32e40p_prefetch_controller.sv" \
  "$RTL/cv32e40p_sleep_unit.sv" \
  "$RTL/cv32e40p_core.sv" \
  "$RTL/cv32e40p_top.sv" \
  "$RTL/cv32e40p_bht.sv" \
  "$RTL/cv32e40p_btb.sv" \
  "$BHV/cv32e40p_sim_clock_gate.sv" \
  "$TB/dp_ram.sv" \
  "$TB/mm_ram.sv" \
  "$TB/amo_shim.sv" \
  "$TB/riscv_gnt_stall.sv" \
  "$TB/riscv_rvalid_stall.sv" \
  "$TB/cv32e40p_random_interrupt_generator.sv" \
  "$TB/cv32e40p_tb_subsystem.sv" \
  "$TB/tb_top.sv" \
  --top-module tb_top \
  --Mdir "$MDIR" \
  -o Vtb_top \
  --trace
