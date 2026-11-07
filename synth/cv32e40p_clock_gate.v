// Synthesis-only shim: synthesizable clock gating cell for CV32E40P.
//
// The shipped RTL's clock gate lives in bhv/cv32e40p_sim_clock_gate.sv and is
// explicitly marked "simulation only, must not be used for ASIC/FPGA synth".
// For the full-core area comparison (BR_PREDICT_EN=0 vs =1) we substitute a
// functionally equivalent latch-based integrated clock gate (ICG). The gate is
// instantiated identically in both configurations, so its area cancels exactly
// in the EN0 vs EN1 delta and does not bias the comparison.
//
// This is NOT a change to the shipped RTL; it is a synthesis-only stand-in,
// consistent with how the real flow would use a technology ICG cell.

module cv32e40p_clock_gate (
    input  wire clk_i,
    input  wire en_i,
    input  wire scan_cg_en_i,
    output wire clk_o
);

  reg clk_en;

  always @(clk_i or en_i or scan_cg_en_i)
    if (clk_i == 1'b0)
      clk_en = en_i | scan_cg_en_i;

  assign clk_o = clk_i & clk_en;

endmodule
