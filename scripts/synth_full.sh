#!/bin/bash
# Full-core synthesis of CV32E40P (baseline vs BR_PREDICT_EN=0 vs =1).
#
#   ./scripts/synth_full.sh
#
# Strategy:
#   1. sv2v converts the full-core SystemVerilog (packages + packed 2D arrays +
#      `import pkg::*`) into plain Verilog-2001 that Yosys `read_verilog` accepts.
#      Yosys 0.33/0.70 cannot parse `import pkg::*` or packed 2D arrays natively;
#      sv2v is the reliable path (verified independently).
#   2. Three configurations are synthesized with the SAME script / flags / tech
#      library (generic gate library via `synth`, no area/timing liberty):
#        - BASE   : commit b353438 (feature baseline, NO predictor at all)
#        - EN=0   : feature branch, BR_PREDICT_EN=0 (predictor "disabled")
#        - EN=1   : feature branch, BR_PREDICT_EN=1 (predictor enabled)
#   3. `stat` reports cell count (area proxy) + flip-flop / memory-bit split.
#
# Honest limitations (never fabricated):
#   - No timing liberty / OpenSTA => WNS / critical path NOT EVALUATED.
#   - No area attributes in cells.lib => area reported as gate-level cell count
#     (and storage-bit split), NOT um^2.
#   - The BTB/BHT use packed 2D arrays; sv2v flattens them to packed vectors,
#     so Yosys expands the variable-index read into a 128:1 mux per bit (a
#     register file, no SRAM). A memory-compiler flow would map the storage to
#     SRAM macros and reduce area; this is stated explicitly, not hidden.

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
BASE_COMMIT="${BASE_COMMIT:-b353438}"

mkdir -p "$LOGS_DIR" "$METRICS_DIR" "$TMPDIR"

{
  echo "sv2v: $("$SV2V" --version 2>&1 | head -1)"
  echo "yosys: $("$YOSYS" --version 2>&1 | head -1)"
  echo "BASE_COMMIT=$BASE_COMMIT"
  echo "HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)"
} | tee "$LOGS_DIR/g5r2_synth_full_environment.txt"

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

BASE_FILES="$(echo "$CORE_FILES" | grep -vE 'cv32e40p_bht|cv32e40p_btb')"

echo "== sv2v: feature branch full core =="
( cd "$RTL" && "$SV2V" -I include --top=cv32e40p_top $CORE_FILES ) \
    > "$TMPDIR/full_core.v" 2> "$LOGS_DIR/g5r2_sv2v_feature.log"
echo "sv2v feature exit: $? (stderr lines: $(wc -l < "$LOGS_DIR/g5r2_sv2v_feature.log"))"
cat "$TMPDIR/full_core.v" "$SYNTH_DIR/cv32e40p_clock_gate.v" > "$TMPDIR/full_core_cg.v"

echo "== sv2v: baseline ($BASE_COMMIT) full core =="
rm -rf "$TMPDIR/base_rtl"
mkdir -p "$TMPDIR/base_rtl"
git -C "$REPO_DIR" archive "$BASE_COMMIT" rtl | tar -x -C "$TMPDIR/base_rtl"
( cd "$TMPDIR/base_rtl/rtl" && "$SV2V" -I include --top=cv32e40p_top $BASE_FILES ) \
    > "$TMPDIR/full_core_base.v" 2> "$LOGS_DIR/g5r2_sv2v_base.log"
echo "sv2v base exit: $? (stderr lines: $(wc -l < "$LOGS_DIR/g5r2_sv2v_base.log"))"
cat "$TMPDIR/full_core_base.v" "$SYNTH_DIR/cv32e40p_clock_gate.v" > "$TMPDIR/full_core_base_cg.v"

synth_one() {
  local vfile="$1"; local chparam="$2"; local log="$3"
  local cp=""
  [ -n "$chparam" ] && cp="-chparam $chparam"
  "$YOSYS" -Q -p "
    read_verilog $vfile;
    hierarchy -top cv32e40p_top $cp;
    proc; opt;
    synth -top cv32e40p_top;
    stat -top cv32e40p_top;
  " > "$log" 2>&1
  return $?
}

echo "== Yosys synth: BASE (no predictor) =="
synth_one "$TMPDIR/full_core_base_cg.v" "" "$LOGS_DIR/g5r2_synth_base.log"
echo "base exit: $?"
echo "== Yosys synth: EN=0 =="
synth_one "$TMPDIR/full_core_cg.v" "BR_PREDICT_EN 0" "$LOGS_DIR/g5r2_synth_en0.log"
echo "en0 exit: $?"
echo "== Yosys synth: EN=1 =="
synth_one "$TMPDIR/full_core_cg.v" "BR_PREDICT_EN 1" "$LOGS_DIR/g5r2_synth_en1.log"
echo "en1 exit: $?"

final_section() { awk '/=== cv32e40p_top ===/{s=""} {s=s ORS $0} END{print s}' "$1"; }

total_cells() { final_section "$1" | grep -E "Number of cells:" | tail -1 | grep -oE '[0-9]+'; }

BASE_CELLS=$(total_cells "$LOGS_DIR/g5r2_synth_base.log")
EN0_CELLS=$(total_cells "$LOGS_DIR/g5r2_synth_en0.log")
EN1_CELLS=$(total_cells "$LOGS_DIR/g5r2_synth_en1.log")

BHT_DEPTH=256
BTB_ENTRIES=128
BHT_STORAGE=$(( BHT_DEPTH * 2 ))
BTB_INDEX_W=$(python3 -c "print(($BTB_ENTRIES-1).bit_length())")
BTB_TAGW=$(( 32 - BTB_INDEX_W - 1 ))
BTB_STORAGE=$(( BTB_ENTRIES * (1 + BTB_TAGW + 32) ))

python3 - "$LOGS_DIR/g5r2_synth_base.log" "$LOGS_DIR/g5r2_synth_en0.log" \
         "$LOGS_DIR/g5r2_synth_en1.log" "$METRICS_DIR/g5r2_synth_full_cells.csv" \
         "$METRICS_DIR/g5r2_synth_full_summary.csv" \
         "$BHT_STORAGE" "$BTB_STORAGE" <<'PY'
import sys, re, csv
base_log, en0_log, en1_log, cells_csv, summary_csv, bht_storage, btb_storage = sys.argv[1:]
bht_storage = int(bht_storage); btb_storage = int(btb_storage)

def final_section(path):
    s = ""
    for line in open(path):
        if "=== cv32e40p_top ===" in line:
            s = ""
        s += line
    return s

def total_cells(path):
    m = re.findall(r"Number of cells:\s+(\d+)", final_section(path))
    return int(m[-1]) if m else 0

def cell_types(path):
    out = {}
    for line in final_section(path).splitlines():
        m = re.match(r"\s+(\$_[A-Za-z0-9_]+)\s+(\d+)", line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out

def dff_total(ct):
    return sum(v for k, v in ct.items() if k.startswith(("$_DFF", "$_DFFE", "$_SDFF", "$_ALDFF", "$_DLATCH")))

base = total_cells(base_log); en0 = total_cells(en0_log); en1 = total_cells(en1_log)
b_ct = cell_types(base_log); e0_ct = cell_types(en0_log); e1_ct = cell_types(en1_log)

def grow(a, b):
    return (b - a) / a * 100 if a else float("inf")

rows = [
    ["metric", "value"],
    ["base_cells(b353438,no_predictor)", base],
    ["en0_cells(BR_PREDICT_EN=0)", en0],
    ["en1_cells(BR_PREDICT_EN=1)", en1],
    ["en0_vs_en1_delta_cells", en1 - en0],
    ["en0_vs_en1_area_growth_pct", round(grow(en0, en1), 3)],
    ["base_vs_en1_delta_cells(true_feature_cost)", en1 - base],
    ["base_vs_en1_area_growth_pct", round(grow(base, en1), 3)],
    ["bht_storage_bits(256x2)", bht_storage],
    ["btb_storage_bits(128x(1+tag+32))", btb_storage],
    ["total_predictor_storage_bits", bht_storage + btb_storage],
]
with open(cells_csv, "w", newline="") as f:
    w = csv.writer(f); w.writerows(rows)

all_types = sorted(set(b_ct) | set(e0_ct) | set(e1_ct))
with open(summary_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["cell_type", "base", "en0", "en1", "en1_minus_base", "en1_minus_en0"])
    for t in all_types:
        w.writerow([t, b_ct.get(t,0), e0_ct.get(t,0), e1_ct.get(t,0),
                    e1_ct.get(t,0)-b_ct.get(t,0), e1_ct.get(t,0)-e0_ct.get(t,0)])
    w.writerow(["TOTAL", base, en0, en1, en1-base, en1-en0])
    w.writerow(["TOTAL_DFF_BITS", dff_total(b_ct), dff_total(e0_ct), dff_total(e1_ct),
                dff_total(e1_ct)-dff_total(b_ct), dff_total(e1_ct)-dff_total(e0_ct)])

print(f"BASE={base} EN0={en0} EN1={en1}")
print(f"EN0->EN1 delta={en1-en0} ({grow(en0,en1):.2f}%)")
print(f"BASE->EN1 delta={en1-base} ({grow(base,en1):.2f}%)")
print(f"BHT storage={bht_storage} BTB storage={btb_storage}")
PY
