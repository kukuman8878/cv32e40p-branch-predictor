////////////////////////////////////////////////////////////////////////////////
// tb_bht.sv : self-contained unit testbench for cv32e40p_bht.
//
//   Build:  verilator --binary --timing -Wall ... --top-module tb_bht
//   Run:    ./Vtb_bht   (exit code 0 = PASS, non-zero = FAIL)
//
// Adapted to the SYNCHRONOUS read interface (1-cycle read latency) and
// extended to cover the robustness features: per-entry valid bit, flush_bp_i,
// debug_mode_i, BR_PREDICT_EN gating.
//
// Coverage:
//   T1  reset => all entries invalid -> predict 0 on any PC
//   T2  first update sets valid + full 2-bit saturating transition graph
//   T3  saturation: long taken / not-taken runs never overflow
//   T4  per-entry indexing independence
//   T5  BR_PREDICT_EN = 0 => always predict not-taken, state frozen
//   T6  parameterization smoke: DEPTH = 64 / 256
//   T7  valid-bit gating
//   T8  flush_bp_i clears valid (counter left stale); re-train re-validates
//   T9  debug_mode_i freezes training but keeps reads live
//   T10 randomized sequence (>= 2000 vectors, fixed seed)
////////////////////////////////////////////////////////////////////////////////

`define CHK(cond, msg) \
  begin \
    if (!(cond)) begin \
      $display("  [FAIL] %s", msg); \
      fail = 1'b1; \
    end \
  end

module tb_bht;

  localparam int D1_DEPTH   = 128;
  localparam int D64_DEPTH  = 64;
  localparam int D256_DEPTH = 256;

  logic clk;
  logic rst_n;
  logic fail = 1'b0;

  logic flush_bp;
  logic debug_mode;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] d1_read_pc;
  logic        d1_predict;
  logic        d1_upd_valid;
  logic [31:0] d1_upd_pc;
  logic        d1_upd_taken;

  cv32e40p_bht #(.DEPTH(D1_DEPTH), .BR_PREDICT_EN(1'b1)) dut1 (
    .clk            (clk),
    .rst_n          (rst_n),
    .flush_bp_i     (flush_bp),
    .debug_mode_i   (debug_mode),
    .read_pc_i      (d1_read_pc),
    .predict_taken_o(d1_predict),
    .update_valid_i (d1_upd_valid),
    .update_pc_i    (d1_upd_pc),
    .update_taken_i (d1_upd_taken)
  );

  logic [31:0] dd_read_pc;
  logic        dd_predict;
  logic        dd_upd_valid;
  logic [31:0] dd_upd_pc;
  logic        dd_upd_taken;

  cv32e40p_bht #(.DEPTH(D1_DEPTH), .BR_PREDICT_EN(1'b0)) dut_dis (
    .clk            (clk),
    .rst_n          (rst_n),
    .flush_bp_i     (flush_bp),
    .debug_mode_i   (debug_mode),
    .read_pc_i      (dd_read_pc),
    .predict_taken_o(dd_predict),
    .update_valid_i (dd_upd_valid),
    .update_pc_i    (dd_upd_pc),
    .update_taken_i (dd_upd_taken)
  );

  logic [31:0] d64_read_pc;
  logic        d64_predict;
  logic        d64_upd_valid;
  logic [31:0] d64_upd_pc;
  logic        d64_upd_taken;

  cv32e40p_bht #(.DEPTH(D64_DEPTH), .BR_PREDICT_EN(1'b1)) dut64 (
    .clk            (clk),
    .rst_n          (rst_n),
    .flush_bp_i     (flush_bp),
    .debug_mode_i   (debug_mode),
    .read_pc_i      (d64_read_pc),
    .predict_taken_o(d64_predict),
    .update_valid_i (d64_upd_valid),
    .update_pc_i    (d64_upd_pc),
    .update_taken_i (d64_upd_taken)
  );

  logic [31:0] d256_read_pc;
  logic        d256_predict;
  logic        d256_upd_valid;
  logic [31:0] d256_upd_pc;
  logic        d256_upd_taken;

  cv32e40p_bht #(.DEPTH(D256_DEPTH), .BR_PREDICT_EN(1'b1)) dut256 (
    .clk            (clk),
    .rst_n          (rst_n),
    .flush_bp_i     (flush_bp),
    .debug_mode_i   (debug_mode),
    .read_pc_i      (d256_read_pc),
    .predict_taken_o(d256_predict),
    .update_valid_i (d256_upd_valid),
    .update_pc_i    (d256_upd_pc),
    .update_taken_i (d256_upd_taken)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(posedge clk);
    #1;
  endtask

  task automatic chk(ref logic [31:0] rpc, ref logic predict,
                     input logic [31:0] pc, input logic exp, input string what);
    rpc = pc;
    @(posedge clk);
    #1;
    `CHK(predict === exp, $sformatf("%s: pc=%08h predict=%0b exp=%0b", what, pc, predict, exp))
  endtask

  task automatic upd(ref logic [31:0] upc, ref logic utaken, ref logic uvalid,
                     input logic [31:0] pc, input logic taken);
    upc    = pc;
    utaken = taken;
    uvalid = 1'b1;
    @(posedge clk);
    #1;
    uvalid = 1'b0;
  endtask

  task automatic do_flush();
    flush_bp = 1'b1;
    @(posedge clk);
    #1;
    flush_bp = 1'b0;
  endtask

  initial begin : test_main
    integer       i;
    integer       seed;
    logic [31:0]  pc;
    logic         taken;
    logic         exp;
    int unsigned  idx;

    logic        ref_valid [0:D1_DEPTH-1];
    logic [1:0]  ref_cnt   [0:D1_DEPTH-1];
    logic [3:0]  state_seen;
    logic        sat_up_seen;
    logic        sat_dn_seen;

    $display("=== BHT unit test begin (sync read + valid/flush/debug) ===");

    rst_n      = 1'b0;
    flush_bp   = 1'b0;
    debug_mode = 1'b0;
    d1_read_pc = 32'h0; d1_upd_valid = 1'b0; d1_upd_pc = 32'h0; d1_upd_taken = 1'b0;
    dd_read_pc = 32'h0; dd_upd_valid = 1'b0; dd_upd_pc = 32'h0; dd_upd_taken = 1'b0;
    d64_read_pc = 32'h0; d64_upd_valid = 1'b0; d64_upd_pc = 32'h0; d64_upd_taken = 1'b0;
    d256_read_pc = 32'h0; d256_upd_valid = 1'b0; d256_upd_pc = 32'h0; d256_upd_taken = 1'b0;

    do_reset();
    $display("  [T1] reset: all entries invalid, predict=0");
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T1 reset predict(0x0000)");
    chk(d1_read_pc, d1_predict, 32'h0000_0080, 1'b0, "T1 reset predict(0x0080)");

    $display("  [T2] first update sets valid; full transition graph (entry 0)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T2 01->10 (predict 1)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T2 10->11 (predict 1)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T2 11->11 sat-up");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T2 11->10 (predict 1)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T2 10->01 (predict 0)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T2 01->00 (predict 0)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T2 00->00 sat-dn");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T2 00->01 (predict 0)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T2 01->10 (predict 1)");

    $display("  [T3] saturation, no overflow (entry 1)");
    for (i = 0; i < 5; i = i + 1) begin
      upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b1);
    end
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b1, "T3 5x taken -> ST(1)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b1, "T3 11->10 no wrap (predict 1)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b1);
    for (i = 0; i < 5; i = i + 1) begin
      upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b0);
    end
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b0, "T3 5x not-taken -> SNT(0)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b0, "T3 00->01 no wrap (predict 0)");

    $display("  [T4] per-entry indexing independence");
    chk(d1_read_pc, d1_predict, 32'h0000_0080, 1'b0, "T4 entry64 still invalid(0)");
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T4 entry0 still WT(1)");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0080, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0080, 1'b1, "T4 entry64 -> WT(1)");
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T4 entry0 unaffected(1)");

    $display("  [T5] BR_PREDICT_EN=0: always not-taken + frozen");
    do_reset();
    chk(dd_read_pc, dd_predict, 32'h0000_0000, 1'b0, "T5 reset predict 0");
    for (i = 0; i < 5; i = i + 1) begin
      upd(dd_upd_pc, dd_upd_taken, dd_upd_valid, 32'h0000_0000, 1'b1);
    end
    chk(dd_read_pc, dd_predict, 32'h0000_0000, 1'b0, "T5 after taken x5 -> still 0");
    chk(dd_read_pc, dd_predict, 32'h0000_0080, 1'b0, "T5 other PC still 0");

    $display("  [T6] parameterization smoke (DEPTH=64/256)");
    do_reset();
    chk(d64_read_pc, d64_predict, 32'h0000_0000, 1'b0, "T6 d64 reset 0");
    upd(d64_upd_pc, d64_upd_taken, d64_upd_valid, 32'h0000_0000, 1'b1);
    chk(d64_read_pc, d64_predict, 32'h0000_0000, 1'b1, "T6 d64 WT(1)");
    chk(d64_read_pc, d64_predict, 32'h0000_0040, 1'b0, "T6 d64 idx32 invalid(0)");
    chk(d256_read_pc, d256_predict, 32'h0000_0000, 1'b0, "T6 d256 reset 0");
    upd(d256_upd_pc, d256_upd_taken, d256_upd_valid, 32'h0000_0000, 1'b1);
    chk(d256_read_pc, d256_predict, 32'h0000_0000, 1'b1, "T6 d256 WT(1)");
    chk(d256_read_pc, d256_predict, 32'h0000_0100, 1'b0, "T6 d256 idx128 invalid(0)");

    $display("  [T7] valid-bit gating (counter 11 but valid=0 -> predict 0)");
    do_reset();
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T7 pre-flush predict 1");
    do_flush();
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T7 post-flush valid=0 -> predict 0");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T7 re-train -> predict 1");

    $display("  [T8] flush_bp_i clears all valid bits");
    do_reset();
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0080, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T8 entry0 valid(1)");
    chk(d1_read_pc, d1_predict, 32'h0000_0080, 1'b1, "T8 entry64 valid(1)");
    do_flush();
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b0, "T8 flush entry0 -> 0");
    chk(d1_read_pc, d1_predict, 32'h0000_0080, 1'b0, "T8 flush entry64 -> 0");
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0000, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0000, 1'b1, "T8 re-train entry0 -> 1");
    chk(d1_read_pc, d1_predict, 32'h0000_0080, 1'b0, "T8 entry64 still invalid -> 0");

    $display("  [T9] debug_mode_i: no training, reads live");
    do_reset();
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b1);
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b1, "T9 entry1 WT(1)");
    debug_mode = 1'b1;
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b1, "T9 debug update ignored (still 1)");
    chk(d1_read_pc, d1_predict, 32'h0000_0004, 1'b0, "T9 debug fresh entry reads 0");
    debug_mode = 1'b0;
    upd(d1_upd_pc, d1_upd_taken, d1_upd_valid, 32'h0000_0002, 1'b0);
    chk(d1_read_pc, d1_predict, 32'h0000_0002, 1'b0, "T9 post-debug update applies -> 0");

    $display("  [T10] random sequence (seed=42, 4096 vectors)");
    do_reset();
    for (i = 0; i < D1_DEPTH; i = i + 1) begin
      ref_valid[i] = 1'b0;
      ref_cnt[i]   = 2'b01;
    end
    state_seen  = 4'b0000;
    sat_up_seen = 1'b0;
    sat_dn_seen = 1'b0;

    seed = 42;
    for (i = 0; i < 4096; i = i + 1) begin
      pc    = $random(seed) & 32'hFFFF_FFFE;
      taken = $random(seed) & 32'h0000_0001;
      idx   = (pc >> 1) & (D1_DEPTH - 1);

      d1_read_pc   = pc;
      d1_upd_pc    = pc;
      d1_upd_taken = taken;
      d1_upd_valid = 1'b1;
      @(posedge clk);
      #1;
      d1_upd_valid = 1'b0;

      exp = ref_valid[idx] && ref_cnt[idx][1];
      `CHK(d1_predict === exp, $sformatf("T10 vec %0d pc=%08h pred=%0b ref=%0b", i, pc, d1_predict, exp))

      state_seen[ref_cnt[idx]] = 1'b1;
      if (taken && (ref_cnt[idx] == 2'b11)) sat_up_seen = 1'b1;
      if (!taken && (ref_cnt[idx] == 2'b00)) sat_dn_seen = 1'b1;

      ref_valid[idx] = 1'b1;
      if (taken) begin
        if (ref_cnt[idx] != 2'b11) ref_cnt[idx] = ref_cnt[idx] + 2'b01;
      end else begin
        if (ref_cnt[idx] != 2'b00) ref_cnt[idx] = ref_cnt[idx] - 2'b01;
      end
    end

    `CHK(state_seen[0] && state_seen[1] && state_seen[2] && state_seen[3],
         "T10 coverage: all 4 states visited")
    `CHK(sat_up_seen, "T10 coverage: saturation-up edge visited")
    `CHK(sat_dn_seen, "T10 coverage: saturation-down edge visited")
    $display("  [T10] state_seen=%b sat_up=%0b sat_dn=%0b", state_seen, sat_up_seen, sat_dn_seen);

    if (fail) begin
      $display("=== BHT UNIT TEST: FAIL ===");
      $fatal(1, "BHT unit test failed");
    end else begin
      $display("=== BHT UNIT TEST: PASS ===");
      $finish;
    end
  end

endmodule
