//
// SYNTHESIS-ONLY SHIM (NOT shipped RTL).
//
// Minimal top that instantiates BHT + BTB exactly as cv32e40p_core.sv does,
// so `yosys synth` can measure the predictor's combined incremental area
// (storage + combinational read/update paths + the pred_taken glue). Update
// gating (bht_update_valid / btb_write_valid) and the pc_id/pc_ex/
// branch_decision wiring are exposed as ports here because the surrounding
// pipeline (id_stage/ex_stage/controller) uses SystemVerilog packages/enums
// that Yosys 0.33 cannot elaborate.
//
// Parameters match the integration build: BHT_DEPTH=256, BTB_ENTRIES=128.
//

module cv32e40p_branch_predictor #(
    parameter bit          BR_PREDICT_EN = 1'b1,
    parameter int unsigned BHT_DEPTH     = 256,
    parameter int unsigned BTB_ENTRIES   = 128
) (
    input  logic clk,
    input  logic rst_n,
    // read (IF/ID) side
    input  logic [31:0] read_pc_i,         // pc_id
    output logic        pred_taken_o,      // EN && btb_hit && bht_taken
    output logic [31:0] btb_target_o,
    // update (EX) side
    input  logic        bht_update_valid_i,  // branch_retired
    input  logic [31:0] update_pc_i,         // pc_ex
    input  logic        update_taken_i,      // branch_decision
    input  logic        btb_write_valid_i,   // branch_retired && branch_decision
    input  logic [31:0] write_target_i       // jump_target_ex
);

  logic bht_predict_taken;
  logic btb_hit;
  logic [31:0] btb_target;

  cv32e40p_btb #(
      .ENTRIES(BTB_ENTRIES)
  ) btb_i (
      .clk            (clk),
      .rst_n          (rst_n),
      .read_pc_i      (read_pc_i),
      .btb_hit_o      (btb_hit),
      .btb_target_o   (btb_target),
      .write_valid_i  (btb_write_valid_i),
      .write_pc_i     (update_pc_i),
      .write_target_i (write_target_i)
  );

  cv32e40p_bht #(
      .DEPTH         (BHT_DEPTH),
      .BR_PREDICT_EN (BR_PREDICT_EN)
  ) bht_i (
      .clk            (clk),
      .rst_n          (rst_n),
      .read_pc_i      (read_pc_i),
      .predict_taken_o(bht_predict_taken),
      .update_valid_i (bht_update_valid_i),
      .update_pc_i    (update_pc_i),
      .update_taken_i (update_taken_i)
  );

  assign btb_target_o  = btb_target;
  assign pred_taken_o  = BR_PREDICT_EN && btb_hit && bht_predict_taken;

endmodule
