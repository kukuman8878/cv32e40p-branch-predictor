// Copyright 2017 Embecosm Limited <www.embecosm.com>
// Copyright 2018 Robert Balas <balasr@student.ethz.ch>
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Top level wrapper for a RI5CY testbench
// Contributor: Robert Balas <balasr@student.ethz.ch>
//              Jeremy Bennett <jeremy.bennett@embecosm.com>

module tb_top #(
    parameter INSTR_RDATA_WIDTH = 32,
    parameter RAM_ADDR_WIDTH = 22,
    parameter BOOT_ADDR = 'h180,
    parameter COREV_PULP = 0,
    parameter COREV_CLUSTER = 0,
    parameter FPU = 0,
    parameter ZFINX = 0,
    parameter NUM_MHPMCOUNTERS = 1,
    parameter BR_PREDICT_EN = 0,
    parameter int unsigned BHT_DEPTH = 256,
    parameter int unsigned BTB_ENTRIES = 128,
    parameter DM_HALTADDRESS = 32'h1A110800
);

  const time          CLK_PHASE_HI = 5ns;
  const time          CLK_PHASE_LO = 5ns;
  const time          CLK_PERIOD = CLK_PHASE_HI + CLK_PHASE_LO;

  const time          STIM_APPLICATION_DEL = CLK_PERIOD * 0.1;
  const time          RESP_ACQUISITION_DEL = CLK_PERIOD * 0.9;
  const time          RESET_DEL = STIM_APPLICATION_DEL;
  const int           RESET_WAIT_CYCLES = 4;

  logic               clk = 'b1;
  logic               rst_n = 'b0;

  int unsigned        cycle_cnt_q;

  // free-running cycle counter for benchmark cycle measurement: counts posedge
  // clk while rst_n is high, reset to 0 during reset.
  int unsigned        cycle_count_q;
  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) cycle_count_q <= 0;
    else        cycle_count_q <= cycle_count_q + 1;
  end

  // stall+flush co-occurrence observation point. These counters are pure
  // observation (they never drive anything), so they cannot affect the cycle
  // counts of existing benchmarks. Active only when the instruction grant
  // stall is injecting delay (STANDARD mode under Verilator).
  integer g5_stall_active_cnt;
  integer g5_stall_flush_coincide_cnt;
  integer g5_stall_mispredict_coincide_cnt;
  always @(posedge clk) begin
    if (rst_n) begin
      if (wrapper_i.ram_i.instr_gnt_stall_i.grant_delay_cnt > 0) begin
        g5_stall_active_cnt = g5_stall_active_cnt + 1;
        if (wrapper_i.top_i.core_i.pc_set)
          g5_stall_flush_coincide_cnt = g5_stall_flush_coincide_cnt + 1;
        if (wrapper_i.top_i.core_i.branch_mispredict)
          g5_stall_mispredict_coincide_cnt = g5_stall_mispredict_coincide_cnt + 1;
      end
    end
  end

  logic               tests_passed;
  logic               tests_failed;
  logic               exit_valid;
  logic        [31:0] exit_value;

  logic               fetch_enable;

  assign fetch_enable = '1;

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("riscy_tb.vcd");
      $dumpvars(0, tb_top);
    end
  end

  initial begin : load_prog
    automatic string firmware;
    automatic int prog_size = 6;

    if ($value$plusargs("firmware=%s", firmware)) begin
      if ($test$plusargs("verbose"))
        $display("[TESTBENCH] %t: loading firmware %0s ...", $time, firmware);
      $readmemh(firmware, wrapper_i.ram_i.dp_ram_i.mem);
      $display("[DBG] mem[0x180..0x18b] = %02x %02x %02x %02x | %02x %02x %02x %02x | %02x %02x %02x %02x",
        wrapper_i.ram_i.dp_ram_i.mem['h180], wrapper_i.ram_i.dp_ram_i.mem['h181],
        wrapper_i.ram_i.dp_ram_i.mem['h182], wrapper_i.ram_i.dp_ram_i.mem['h183],
        wrapper_i.ram_i.dp_ram_i.mem['h184], wrapper_i.ram_i.dp_ram_i.mem['h185],
        wrapper_i.ram_i.dp_ram_i.mem['h186], wrapper_i.ram_i.dp_ram_i.mem['h187],
        wrapper_i.ram_i.dp_ram_i.mem['h188], wrapper_i.ram_i.dp_ram_i.mem['h189],
        wrapper_i.ram_i.dp_ram_i.mem['h18a], wrapper_i.ram_i.dp_ram_i.mem['h18b]);

    end else begin
      $display("No firmware specified");
      $finish;
    end
  end

  initial begin : clock_gen
    forever begin
      #CLK_PHASE_HI clk = 1'b0;
      #CLK_PHASE_LO clk = 1'b1;
    end
  end : clock_gen

  initial begin : reset_gen
    rst_n = 1'b0;

    repeat (RESET_WAIT_CYCLES) begin
      @(posedge clk);
    end

    #RESET_DEL rst_n = 1'b1;
    if ($test$plusargs("verbose")) $display("reset deasserted", $time);

  end : reset_gen

  // DEBUG MONITOR - local tb copy only; gated by +verbose so clean benchmark
  // runs print only the program's own stdout
  always @(posedge clk) begin
    if ($test$plusargs("verbose")) begin
      if (wrapper_i.top_i.instr_req_o)
        $display("[MON] t=%0t instr_req=1 addr=0x%08x gnt=%b rvalid=%b rdata=0x%08x",
                 $time, wrapper_i.top_i.instr_addr_o, wrapper_i.top_i.instr_gnt_i,
                 wrapper_i.top_i.instr_rvalid_i, wrapper_i.top_i.instr_rdata_i);
      if (wrapper_i.top_i.data_req_o)
        $display("[MON] t=%0t data_req=1 addr=0x%08x we=%b wdata=0x%08x",
                 $time, wrapper_i.top_i.data_addr_o, wrapper_i.top_i.data_we_o,
                 wrapper_i.top_i.data_wdata_o);
      if (wrapper_i.exit_valid_o)
        $display("[MON] t=%0t exit_valid=1 exit_value=%0d", $time, wrapper_i.exit_value_o);
    end
  end

  initial begin : timing_format
    $timeformat(-9, 0, "ns", 9);
  end : timing_format

  always_ff @(posedge clk, negedge rst_n) begin
    automatic int maxcycles;
    if ($value$plusargs("maxcycles=%d", maxcycles)) begin
      if (~rst_n) begin
        cycle_cnt_q <= 0;
      end else begin
        cycle_cnt_q <= cycle_cnt_q + 1;
        if (cycle_cnt_q >= maxcycles) begin
          $fatal(2, "Simulation aborted due to maximum cycle limit");
        end
      end
    end
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (tests_passed) begin
      $display("[CYCLE] cycle_count = %0d (finish time %0t)", cycle_count_q, $time);
      $display("[BPRED] branch_total=%0d pred_taken=%0d correct=%0d mispredict=%0d",
               wrapper_i.top_i.core_i.bp_branch_total,
               wrapper_i.top_i.core_i.bp_pred_taken,
               wrapper_i.top_i.core_i.bp_correct,
               wrapper_i.top_i.core_i.bp_mispredict);
      $display("[MINSTRET] minstret=%0d", wrapper_i.top_i.core_i.cs_registers_i.mhpmcounter_q[2]);
      if ($test$plusargs("stall_observe")) begin
        $display("[STALL_OBS] stall_active=%0d stall_flush_coincide=%0d stall_mispredict_coincide=%0d",
                 g5_stall_active_cnt, g5_stall_flush_coincide_cnt, g5_stall_mispredict_coincide_cnt);
      end
      $display("ALL TESTS PASSED");
      $finish;
    end
    if (tests_failed) begin
      $display("[CYCLE] cycle_count = %0d (finish time %0t)", cycle_count_q, $time);
      $display("[BPRED] branch_total=%0d pred_taken=%0d correct=%0d mispredict=%0d",
               wrapper_i.top_i.core_i.bp_branch_total,
               wrapper_i.top_i.core_i.bp_pred_taken,
               wrapper_i.top_i.core_i.bp_correct,
               wrapper_i.top_i.core_i.bp_mispredict);
      $display("[MINSTRET] minstret=%0d", wrapper_i.top_i.core_i.cs_registers_i.mhpmcounter_q[2]);
      if ($test$plusargs("stall_observe")) begin
        $display("[STALL_OBS] stall_active=%0d stall_flush_coincide=%0d stall_mispredict_coincide=%0d",
                 g5_stall_active_cnt, g5_stall_flush_coincide_cnt, g5_stall_mispredict_coincide_cnt);
      end
      $display("TEST(S) FAILED!");
      $finish;
    end
    if (exit_valid) begin
      $display("[CYCLE] cycle_count = %0d (finish time %0t)", cycle_count_q, $time);
      $display("[BPRED] branch_total=%0d pred_taken=%0d correct=%0d mispredict=%0d",
               wrapper_i.top_i.core_i.bp_branch_total,
               wrapper_i.top_i.core_i.bp_pred_taken,
               wrapper_i.top_i.core_i.bp_correct,
               wrapper_i.top_i.core_i.bp_mispredict);
      $display("[MINSTRET] minstret=%0d", wrapper_i.top_i.core_i.cs_registers_i.mhpmcounter_q[2]);
      if ($test$plusargs("stall_observe")) begin
        $display("[STALL_OBS] stall_active=%0d stall_flush_coincide=%0d stall_mispredict_coincide=%0d",
                 g5_stall_active_cnt, g5_stall_flush_coincide_cnt, g5_stall_mispredict_coincide_cnt);
      end
      if (exit_value == 0) $display("EXIT SUCCESS");
      else $display("EXIT FAILURE: %d", exit_value);
      $finish;
    end
  end

  cv32e40p_tb_subsystem #(
      .INSTR_RDATA_WIDTH(INSTR_RDATA_WIDTH),
      .RAM_ADDR_WIDTH   (RAM_ADDR_WIDTH),
      .BOOT_ADDR        (BOOT_ADDR),
      .COREV_PULP       (COREV_PULP),
      .COREV_CLUSTER     (COREV_CLUSTER),
      .FPU              (FPU),
      .ZFINX            (ZFINX),
      .NUM_MHPMCOUNTERS (NUM_MHPMCOUNTERS),
      .BR_PREDICT_EN    (BR_PREDICT_EN),
      .BHT_DEPTH        (BHT_DEPTH),
      .BTB_ENTRIES      (BTB_ENTRIES),
      .DM_HALTADDRESS   (DM_HALTADDRESS)
  ) wrapper_i (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .fetch_enable_i(fetch_enable),
      .tests_passed_o(tests_passed),
      .tests_failed_o(tests_failed),
      .exit_valid_o  (exit_valid),
      .exit_value_o  (exit_value)
  );

`ifndef VERILATOR
  initial begin
    assert (INSTR_RDATA_WIDTH == 32)
    else $fatal("invalid INSTR_RDATA_WIDTH, choose 32");
  end
`endif

endmodule  // tb_top
