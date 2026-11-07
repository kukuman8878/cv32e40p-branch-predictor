//
// SYNTHESIS-ONLY SHIM (NOT shipped RTL, NOT used in simulation/verification).
//
// Yosys 0.33's SystemVerilog frontend does not support the packed multi-
// dimensional array declaration used by the real RTL:
//     rtl/cv32e40p_bht.sv   logic [DEPTH-1:0][1:0] counter_q;
//
// This file is a SEMANTICALLY EQUIVALENT rewrite of cv32e40p_bht using an
// unpacked memory array (reg [1:0] counter_q [0:DEPTH-1]) that Yosys can
// elaborate. Storage, read path, update path, saturating counter behavior,
// reset value (weakly-not-taken = 2'b01) and the BR_PREDICT_EN freeze/bypass
// are preserved bit-for-bit. It exists solely to let `yosys synth` measure the
// predictor's incremental area. The functional/simulation evidence comes from
// the real RTL (see the verification scripts).
//

module cv32e40p_bht #(
    parameter int unsigned DEPTH         = 256,
    parameter bit          BR_PREDICT_EN = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [31:0] read_pc_i,
    output logic        predict_taken_o,
    input  logic        update_valid_i,
    input  logic [31:0] update_pc_i,
    input  logic        update_taken_i
);

  localparam int unsigned INDEX_W = $clog2(DEPTH);

  logic [INDEX_W-1:0] read_index;
  logic [INDEX_W-1:0] update_index;

  reg   [1:0] counter_q [0:DEPTH-1];
  logic [1:0] counter_n;
  integer     i;

  assign read_index   = read_pc_i[INDEX_W:1];
  assign update_index = update_pc_i[INDEX_W:1];

  always_comb begin
    if (update_taken_i) begin
      counter_n = (counter_q[update_index] == 2'b11) ? 2'b11 :
                  counter_q[update_index] + 2'b01;
    end else begin
      counter_n = (counter_q[update_index] == 2'b00) ? 2'b00 :
                  counter_q[update_index] - 2'b01;
    end
  end

  assign predict_taken_o = BR_PREDICT_EN ? counter_q[read_index][1] : 1'b0;

  always_ff @(posedge clk, negedge rst_n) begin : BHT_STATE
    if (rst_n == 1'b0) begin
      for (i = 0; i < DEPTH; i = i + 1)
        counter_q[i] <= 2'b01;
    end else if (update_valid_i && BR_PREDICT_EN) begin
      counter_q[update_index] <= counter_n;
    end
  end

endmodule
