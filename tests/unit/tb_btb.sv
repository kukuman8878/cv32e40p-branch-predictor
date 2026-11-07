////////////////////////////////////////////////////////////////////////////////
// tb_btb.sv : self-contained unit testbench for cv32e40p_btb.
//
//   Build:  verilator --binary --timing -Wall ... --top-module tb_btb
//   Run:    ./Vtb_btb   (exit code 0 = PASS, non-zero = FAIL)
//
// Adapted to the SYNCHRONOUS read interface (1-cycle read latency) and
// extended to cover the robustness features: BR_PREDICT_EN gating, flush_bp_i,
// debug_mode_i.
//
// Coverage:
//   T1  reset => no hit on any PC
//   T2  first write then read => tag hit with correct target
//   T3  tag conflict (same index, different tag) => evict
//   T4  invalid entry => no hit
//   T5  full 32-bit target round-trip
//   T6  parameterization smoke: ENTRIES = 128
//   T7  BR_PREDICT_EN = 0 => hit forced 0, write disabled
//   T8  flush_bp_i => clears all valid bits
//   T9  debug_mode_i => write disabled, read stays live
//   T10 randomized sequence (>= 2000 vectors, fixed seed)
////////////////////////////////////////////////////////////////////////////////

`define CHK(cond, msg) \
  begin \
    if (!(cond)) begin \
      $display("  [FAIL] %s", msg); \
      fail = 1'b1; \
    end \
  end

module tb_btb;

  localparam int D1_ENTRIES   = 32;
  localparam int D128_ENTRIES = 128;

  localparam int D1_IDXW = $clog2(D1_ENTRIES);
  localparam int D1_TAGW = 32 - D1_IDXW - 1;

  logic clk;
  logic rst_n;
  logic fail = 1'b0;

  logic flush_bp;
  logic debug_mode;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] d1_read_pc;
  logic        d1_hit;
  logic [31:0] d1_target;
  logic        d1_wr_valid;
  logic [31:0] d1_wr_pc;
  logic [31:0] d1_wr_target;

  cv32e40p_btb #(.ENTRIES(D1_ENTRIES), .BR_PREDICT_EN(1'b1)) dut1 (
    .clk           (clk),
    .rst_n         (rst_n),
    .flush_bp_i    (flush_bp),
    .debug_mode_i  (debug_mode),
    .read_pc_i     (d1_read_pc),
    .btb_hit_o     (d1_hit),
    .btb_target_o  (d1_target),
    .write_valid_i (d1_wr_valid),
    .write_pc_i    (d1_wr_pc),
    .write_target_i(d1_wr_target)
  );

  logic [31:0] dd_read_pc;
  logic        dd_hit;
  logic [31:0] dd_target;
  logic        dd_wr_valid;
  logic [31:0] dd_wr_pc;
  logic [31:0] dd_wr_target;

  cv32e40p_btb #(.ENTRIES(D1_ENTRIES), .BR_PREDICT_EN(1'b0)) dut_dis (
    .clk           (clk),
    .rst_n         (rst_n),
    .flush_bp_i    (flush_bp),
    .debug_mode_i  (debug_mode),
    .read_pc_i     (dd_read_pc),
    .btb_hit_o     (dd_hit),
    .btb_target_o  (dd_target),
    .write_valid_i (dd_wr_valid),
    .write_pc_i    (dd_wr_pc),
    .write_target_i(dd_wr_target)
  );

  logic [31:0] d128_read_pc;
  logic        d128_hit;
  logic [31:0] d128_target;
  logic        d128_wr_valid;
  logic [31:0] d128_wr_pc;
  logic [31:0] d128_wr_target;

  cv32e40p_btb #(.ENTRIES(D128_ENTRIES), .BR_PREDICT_EN(1'b1)) dut128 (
    .clk           (clk),
    .rst_n         (rst_n),
    .flush_bp_i    (flush_bp),
    .debug_mode_i  (debug_mode),
    .read_pc_i     (d128_read_pc),
    .btb_hit_o     (d128_hit),
    .btb_target_o  (d128_target),
    .write_valid_i (d128_wr_valid),
    .write_pc_i    (d128_wr_pc),
    .write_target_i(d128_wr_target)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(posedge clk);
    #1;
  endtask

  function automatic logic [31:0] mk_pc(input int unsigned index,
                                        input logic [31:0] tag,
                                        input int unsigned idxw);
    return ((tag & ((32'hFFFF_FFFF >> idxw) >> 1)) << (idxw + 1)) | (index << 1);
  endfunction

  task automatic wr(ref logic [31:0] wpc, ref logic [31:0] wtgt, ref logic wvalid,
                    input logic [31:0] pc, input logic [31:0] target);
    wpc    = pc;
    wtgt   = target;
    wvalid = 1'b1;
    @(posedge clk);
    #1;
    wvalid = 1'b0;
  endtask

  task automatic rd(ref logic [31:0] rpc, ref logic hit, ref logic [31:0] tgt,
                    input logic [31:0] pc, input logic exp_hit,
                    input logic [31:0] exp_tgt, input string what);
    rpc = pc;
    @(posedge clk);
    #1;
    `CHK(hit === exp_hit, $sformatf("%s: pc=%08h hit=%0b exp=%0b", what, pc, hit, exp_hit))
    if (exp_hit) begin
      `CHK(tgt === exp_tgt, $sformatf("%s: pc=%08h tgt=%08h exp=%08h", what, pc, tgt, exp_tgt))
    end
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
    logic [31:0]  target;
    logic         do_write;
    logic         exp_hit;
    int unsigned  idx;

    logic                 ref_valid  [0:D1_ENTRIES-1];
    logic [D1_TAGW-1:0]   ref_tag    [0:D1_ENTRIES-1];
    logic [31:0]          ref_target [0:D1_ENTRIES-1];
    logic                 hit_seen, miss_seen, evict_seen;

    $display("=== BTB unit test begin (sync read + flush/debug/EN gating) ===");

    rst_n      = 1'b0;
    flush_bp   = 1'b0;
    debug_mode = 1'b0;
    d1_read_pc = 32'h0; d1_wr_valid = 1'b0; d1_wr_pc = 32'h0; d1_wr_target = 32'h0;
    dd_read_pc = 32'h0; dd_wr_valid = 1'b0; dd_wr_pc = 32'h0; dd_wr_target = 32'h0;
    d128_read_pc = 32'h0; d128_wr_valid = 1'b0; d128_wr_pc = 32'h0; d128_wr_target = 32'h0;

    do_reset();
    $display("  [T1] reset: no hit on any PC");
    rd(d1_read_pc, d1_hit, d1_target, 32'h0000_0000, 1'b0, 32'h0, "T1 reset pc=0");
    rd(d1_read_pc, d1_hit, d1_target, 32'h0000_0080, 1'b0, 32'h0, "T1 reset pc=0x80");
    rd(d1_read_pc, d1_hit, d1_target, 32'h8000_0000, 1'b0, 32'h0, "T1 reset pc=0x80000000");

    $display("  [T2] first write -> tag hit");
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 32'hDEAD_BEEF);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b1, 32'hDEAD_BEEF, "T2 hit target");

    $display("  [T3] tag alias: same index, different tag evicts");
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(0, 32'h0015_5555, D1_IDXW), 32'hCAFE_0000);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b0, 32'h0, "T3 old tag now miss");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h0015_5555, D1_IDXW), 1'b1, 32'hCAFE_0000, "T3 new tag hit");

    $display("  [T4] invalid entry => miss");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(5, 32'h0000_0000, D1_IDXW), 1'b0, 32'h0, "T4 invalid idx5 miss");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(1, 32'h0015_5555, D1_IDXW), 1'b0, 32'h0, "T4 same tag diff idx miss");

    $display("  [T5] full 32-bit target round-trip");
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(7, 32'h0000_0000, D1_IDXW), 32'h0000_0000);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(7, 32'h0000_0000, D1_IDXW), 1'b1, 32'h0000_0000, "T5 target=0");
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(7, 32'h0000_0001, D1_IDXW), 32'hFFFF_FFFF);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(7, 32'h0000_0001, D1_IDXW), 1'b1, 32'hFFFF_FFFF, "T5 target=all-ones");
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(7, 32'h0000_0002, D1_IDXW), 32'h5A5A_A5A5);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(7, 32'h0000_0002, D1_IDXW), 1'b1, 32'h5A5A_A5A5, "T5 target=pattern");

    $display("  [T6] parameterization smoke (ENTRIES=128)");
    do_reset();
    rd(d128_read_pc, d128_hit, d128_target, 32'h0000_0000, 1'b0, 32'h0, "T6 d128 reset miss");
    wr(d128_wr_pc, d128_wr_target, d128_wr_valid, 32'h0000_0000, 32'h1111_2222);
    rd(d128_read_pc, d128_hit, d128_target, 32'h0000_0000, 1'b1, 32'h1111_2222, "T6 d128 hit");
    rd(d128_read_pc, d128_hit, d128_target, 32'h0000_0080, 1'b0, 32'h0, "T6 d128 idx64 miss");

    $display("  [T7] BR_PREDICT_EN=0: hit=0 target=0 write disabled");
    do_reset();
    wr(dd_wr_pc, dd_wr_target, dd_wr_valid,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 32'hDEAD_BEEF);
    rd(dd_read_pc, dd_hit, dd_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b0, 32'h0, "T7 EN0 write then read -> miss");
    rd(dd_read_pc, dd_hit, dd_target, 32'h0000_0000, 1'b0, 32'h0, "T7 EN0 other pc -> miss");

    $display("  [T8] flush_bp_i clears all valid bits");
    do_reset();
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 32'hDEAD_BEEF);
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(1, 32'h0015_5555, D1_IDXW), 32'hCAFE_0000);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b1, 32'hDEAD_BEEF, "T8 idx0 valid");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(1, 32'h0015_5555, D1_IDXW), 1'b1, 32'hCAFE_0000, "T8 idx1 valid");
    do_flush();
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b0, 32'h0, "T8 flush idx0 -> miss");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(1, 32'h0015_5555, D1_IDXW), 1'b0, 32'h0, "T8 flush idx1 -> miss");
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 32'hDEAD_BEEF);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b1, 32'hDEAD_BEEF, "T8 re-write idx0 -> hit");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(1, 32'h0015_5555, D1_IDXW), 1'b0, 32'h0, "T8 idx1 still miss");

    $display("  [T9] debug_mode_i: write disabled, read live");
    do_reset();
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 32'hDEAD_BEEF);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b1, 32'hDEAD_BEEF, "T9 pre-debug hit");
    debug_mode = 1'b1;
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(2, 32'h0000_0000, D1_IDXW), 32'hAAAA_BBBB);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(2, 32'h0000_0000, D1_IDXW), 1'b0, 32'h0, "T9 debug write ignored -> miss");
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(0, 32'h003A_AAAA, D1_IDXW), 1'b1, 32'hDEAD_BEEF, "T9 debug read live");
    debug_mode = 1'b0;
    wr(d1_wr_pc, d1_wr_target, d1_wr_valid,
       mk_pc(2, 32'h0000_0000, D1_IDXW), 32'hAAAA_BBBB);
    rd(d1_read_pc, d1_hit, d1_target,
       mk_pc(2, 32'h0000_0000, D1_IDXW), 1'b1, 32'hAAAA_BBBB, "T9 post-debug write -> hit");

    $display("  [T10] random sequence (seed=7, 4096 vectors)");
    do_reset();
    for (i = 0; i < D1_ENTRIES; i = i + 1) begin
      ref_valid[i]  = 1'b0;
      ref_tag[i]    = '0;
      ref_target[i] = '0;
    end
    hit_seen   = 1'b0;
    miss_seen  = 1'b0;
    evict_seen = 1'b0;

    seed = 7;
    for (i = 0; i < 4096; i = i + 1) begin
      idx      = $random(seed) & 32'h0000_0007;
      pc       = (($random(seed) & 32'h0000_000F) << (D1_IDXW + 1)) | (idx << 1);
      target   = $random(seed);
      do_write = $random(seed) & 32'h0000_0001;

      d1_read_pc = pc;
      d1_wr_pc   = pc;
      d1_wr_target = target;
      d1_wr_valid  = do_write;
      @(posedge clk);
      #1;
      d1_wr_valid = 1'b0;

      exp_hit = ref_valid[idx] && (ref_tag[idx] == (pc >> (D1_IDXW + 1)));
      `CHK(d1_hit === exp_hit, $sformatf("T10 vec %0d pc=%08h hit=%0b ref=%0b", i, pc, d1_hit, exp_hit))
      if (exp_hit) begin
        hit_seen = 1'b1;
        `CHK(d1_target === ref_target[idx], $sformatf("T10 vec %0d target mismatch", i))
      end else begin
        miss_seen = 1'b1;
      end

      if (do_write) begin
        if (ref_valid[idx] && (ref_tag[idx] != (pc >> (D1_IDXW + 1)))) evict_seen = 1'b1;
        ref_valid[idx]  = 1'b1;
        ref_tag[idx]    = pc >> (D1_IDXW + 1);
        ref_target[idx] = target;
      end
    end

    `CHK(hit_seen,   "T10 coverage: hit observed")
    `CHK(miss_seen,  "T10 coverage: miss observed")
    `CHK(evict_seen, "T10 coverage: eviction observed")
    $display("  [T10] hit=%0b miss=%0b evict=%0b", hit_seen, miss_seen, evict_seen);

    if (fail) begin
      $display("=== BTB UNIT TEST: FAIL ===");
      $fatal(1, "BTB unit test failed");
    end else begin
      $display("=== BTB UNIT TEST: PASS ===");
      $finish;
    end
  end

endmodule
