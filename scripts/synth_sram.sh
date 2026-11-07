#!/bin/bash
# Full-core synthesis of the synchronous-read (SRAM/BRAM) BTB/BHT.
#
#   ./scripts/synth_sram.sh
#
# Purpose (fixes the area explosion, BTB 62075 cells as a 128:1 read mux):
#   1. sv2v converts the feature full core (same file list as synth_full.sh).
#   2. Generic `synth` (memory_map, NO block RAM) on EN0/EN1  -> cell count.
#      This is the apples-to-apples "sync vs async read" comparison against the
#      historical BASE 43082 / EN0 105403 / EN1 110036 (same flow).
#   3. `memory_bram -rules +/xilinx/brams_xcv.txt` is attempted and its failure
#      is recorded verbatim (Yosys 0.33 memory_bram uses the OLD rule syntax,
#      the shipped xilinx rules use the NEW `ram block` syntax).
#   4. `memory_libmap` (the 0.33 replacement) maps the BTB tag+target array to
#      Xilinx block-RAM macros; cell count + macro count/bits are recorded with
#      and without block-RAM mapping (same manual `abc -g simple` flow).
#
# No rtl/*.sv is modified. All artifacts land under project/metrics/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${REPO_DIR:-$PROJECT_DIR/../cv32e40p}"
RTL="$REPO_DIR/rtl"
SYNTH_DIR="$PROJECT_DIR/synth"
METRICS_DIR="$PROJECT_DIR/metrics"
LOGS_DIR="$METRICS_DIR/logs"
TMPDIR="${TMPDIR:-$PROJECT_DIR/synth/synth_full_tmp}"

SV2V="${SV2V:-$PROJECT_DIR/tools/sv2v}"
YOSYS="${YOSYS:-yosys}"

mkdir -p "$LOGS_DIR" "$METRICS_DIR" "$TMPDIR"

{
  echo "sv2v: $("$SV2V" --version 2>&1 | head -1)"
  echo "yosys: $("$YOSYS" --version 2>&1 | head -1)"
  echo "HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)"
  echo "branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
  echo "release/reviewed=$(git -C "$REPO_DIR" rev-parse release/reviewed)"
} | tee "$LOGS_DIR/sram_synth_environment.txt"

CORE_FILES="
include/cv32e40p_apu_core_pkg.sv
include/cv32e40p_fpu_pkg.sv
include/cv32e40p_pkg.sv
cv32e40p_if_stage.sv
cv32e40p_cs_registers.sv
cv32e40p_register_file_ff.sv
cv32e40p_load_store_unit.sv
cv32e40p_id_stage.sv
cv32e40p_aligner.sv
cv32e40p_decoder.sv
cv32e40p_compressed_decoder.sv
cv32e40p_fifo.sv
cv32e40p_prefetch_buffer.sv
cv32e40p_hwloop_regs.sv
cv32e40p_mult.sv
cv32e40p_int_controller.sv
cv32e40p_ex_stage.sv
cv32e40p_alu_div.sv
cv32e40p_alu.sv
cv32e40p_ff_one.sv
cv32e40p_popcnt.sv
cv32e40p_apu_disp.sv
cv32e40p_controller.sv
cv32e40p_obi_interface.sv
cv32e40p_prefetch_controller.sv
cv32e40p_sleep_unit.sv
cv32e40p_core.sv
cv32e40p_top.sv
cv32e40p_bht.sv
cv32e40p_btb.sv
"

echo "== sv2v: feature branch full core =="
( cd "$RTL" && "$SV2V" -I include --top=cv32e40p_top $CORE_FILES ) \
    > "$TMPDIR/full_core_sram.v" 2> "$LOGS_DIR/sram_sv2v.log"
echo "sv2v exit: $?"
cat "$TMPDIR/full_core_sram.v" "$SYNTH_DIR/cv32e40p_clock_gate.v" > "$TMPDIR/full_core_sram_cg.v"

VFILE="$TMPDIR/full_core_sram_cg.v"

generic_synth() {
  local chparam="$1"; local log="$2"
  "$YOSYS" -Q -p "
    read_verilog $VFILE;
    hierarchy -top cv32e40p_top $chparam;
    proc; opt;
    synth -top cv32e40p_top;
    stat -top cv32e40p_top;
  " > "$log" 2>&1
  return $?
}

echo "== generic synth EN0 =="
generic_synth "-chparam BR_PREDICT_EN 0" "$LOGS_DIR/sram_synth_en0.log"; echo "en0 exit: $?"
echo "== generic synth EN1 =="
generic_synth "-chparam BR_PREDICT_EN 1" "$LOGS_DIR/sram_synth_en1.log"; echo "en1 exit: $?"

echo "== memory_bram attempt (xilinx rules) =="
"$YOSYS" -Q -p "
  read_verilog $VFILE;
  hierarchy -top cv32e40p_top -chparam BR_PREDICT_EN 1;
  proc; opt -nodffe -nosdff; memory_dff; memory -nomap;
  memory_bram -rules +/xilinx/brams_xcv.txt;
" > "$LOGS_DIR/sram_memory_bram.log" 2>&1
BRAM_RC=$?
echo "memory_bram exit: $BRAM_RC (see sram_memory_bram.log)"

libmap_synth() {
  local withbram="$1"; local log="$2"
  local libmap=""
  [ "$withbram" = "1" ] && libmap="memory_libmap -lib +/xilinx/brams_xcv.txt; techmap -map +/xilinx/brams_xcv_map.v;"
  "$YOSYS" -Q -p "
    read_verilog $VFILE;
    hierarchy -top cv32e40p_top -chparam BR_PREDICT_EN 1;
    proc;
    flatten;
    opt_expr; opt_clean; check;
    opt -nodffe -nosdff;
    fsm; opt; wreduce; peepopt; opt_clean;
    memory_dff; memory -nomap;
    $libmap
    memory_map;
    techmap; opt -fast;
    abc -g simple;
    opt -fast; opt_clean;
    stat -top cv32e40p_top;
  " > "$log" 2>&1
  return $?
}

echo "== memory_libmap EN1 (no block RAM) =="
libmap_synth 0 "$LOGS_DIR/sram_libmap_en1_nobram.log"; echo "nobram exit: $?"
echo "== memory_libmap EN1 (with block RAM) =="
libmap_synth 1 "$LOGS_DIR/sram_libmap_en1_bram.log"; echo "bram exit: $?"

cells_of() { sed -n '/=== cv32e40p_top ===/,$p' "$1" | grep -E "Number of cells:" | grep -oE '[0-9]+' | tail -1; }
ramb_of()   { sed -n '/=== cv32e40p_top ===/,$p' "$1" | grep -E '^\s+RAMB[0-9A-Za-z_]+\s+[0-9]+' | awk '{print $2"="$1}' | tr '\n' ';'; }
mapping_of(){ grep -oE 'mapping memory .* via .*' "$1" | head -1; }

EN0_CELLS=$(cells_of "$LOGS_DIR/sram_synth_en0.log")
EN1_CELLS=$(cells_of "$LOGS_DIR/sram_synth_en1.log")
NOBRAM_CELLS=$(cells_of "$LOGS_DIR/sram_libmap_en1_nobram.log")
BRAM_CELLS=$(cells_of "$LOGS_DIR/sram_libmap_en1_bram.log")

BHT_DEPTH=256
BTB_ENTRIES=32
BHT_STORAGE=$(( BHT_DEPTH * 2 ))
BTB_INDEX_W=$(python3 -c "print(($BTB_ENTRIES-1).bit_length())")
BTB_TAGW=$(( 32 - BTB_INDEX_W - 1 ))
BTB_STORAGE=$(( BTB_ENTRIES * (BTB_TAGW + 32) ))

SUMMARY="$METRICS_DIR/sram_synth_summary.csv"
{
  echo "metric,value"
  echo "en0_cells_generic_synth(sync-read,no_bram),$EN0_CELLS"
  echo "en1_cells_generic_synth(sync-read,no_bram),$EN1_CELLS"
  echo "en1_cells_manual_flow(no_bram),$NOBRAM_CELLS"
  echo "en1_cells_manual_flow(with_bram),$BRAM_CELLS"
  echo "en1_ramb_macros,$(ramb_of "$LOGS_DIR/sram_libmap_en1_bram.log")"
  echo "memory_bram_exit_code,$BRAM_RC"
  echo "btb_storage_bits_tag_target(${BTB_ENTRIES}x$((BTB_TAGW+32))),$BTB_STORAGE"
  echo "bht_storage_bits(256x2),$BHT_STORAGE"
  echo "libmap_mapping,$(mapping_of "$LOGS_DIR/sram_libmap_en1_bram.log")"
} > "$SUMMARY"

echo
echo "================ SRAM SYNTH SUMMARY ================"
cat "$SUMMARY"
echo "generic EN0=$EN0_CELLS EN1=$EN1_CELLS (historical BASE 43082 / EN0 105403 / EN1 110036)"
echo "manual EN1 no-BRAM=$NOBRAM_CELLS  with-BRAM=$BRAM_CELLS"
echo "===================================================="

exit 0
