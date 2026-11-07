//
// SYNTHESIS-ONLY SHIM (NOT shipped RTL, NOT used in simulation/verification).
//
// Yosys 0.33's SystemVerilog frontend does not support the packed multi-
// dimensional array declarations used by the real RTL:
//     rtl/cv32e40p_btb.sv   logic [ENTRIES-1:0][TAG_W-1:0] tag_q;
//     rtl/cv32e40p_btb.sv   logic [ENTRIES-1:0][31:0]      target_q;
//
// This file is a SEMANTICALLY EQUIVALENT rewrite of cv32e40p_btb using unpacked
// memory arrays that Yosys can elaborate. Storage, direct-mapped tag match,
// target read, valid bit, eviction-on-conflict and asynchronous valid-clear are
// preserved. It exists solely to let `yosys synth` measure the predictor's
// incremental area. Functional/simulation evidence comes from the real RTL.
//

module cv32e40p_btb #(
    parameter int unsigned ENTRIES = 128
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [31:0] read_pc_i,
    output logic        btb_hit_o,
    output logic [31:0] btb_target_o,
    input  logic        write_valid_i,
    input  logic [31:0] write_pc_i,
    input  logic [31:0] write_target_i
);

  localparam int unsigned INDEX_W = $clog2(ENTRIES);
  localparam int unsigned TAG_W   = 32 - INDEX_W - 1;

  logic [INDEX_W-1:0] read_index;
  logic [TAG_W-1:0]   read_tag;
  logic [INDEX_W-1:0] write_index;
  logic [TAG_W-1:0]   write_tag;

  reg          valid_q   [0:ENTRIES-1];
  reg [TAG_W-1:0] tag_q  [0:ENTRIES-1];
  reg [31:0]      target_q [0:ENTRIES-1];
  integer     i;

  assign read_index  = read_pc_i[INDEX_W:1];
  assign read_tag    = read_pc_i[31:INDEX_W+1];
  assign write_index = write_pc_i[INDEX_W:1];
  assign write_tag   = write_pc_i[31:INDEX_W+1];

  assign btb_hit_o    = valid_q[read_index] && (tag_q[read_index] == read_tag);
  assign btb_target_o = target_q[read_index];

  always_ff @(posedge clk, negedge rst_n) begin : BTB_STATE
    if (rst_n == 1'b0) begin
      for (i = 0; i < ENTRIES; i = i + 1)
        valid_q[i] <= 1'b0;
    end else if (write_valid_i) begin
      valid_q[write_index]  <= 1'b1;
      tag_q[write_index]    <= write_tag;
      target_q[write_index] <= write_target_i;
    end
  end

endmodule
