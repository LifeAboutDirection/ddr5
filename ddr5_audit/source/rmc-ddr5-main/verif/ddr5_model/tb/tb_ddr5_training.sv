// ---------------------------------------------------------------------------
// tb_ddr5_training.sv — Stage 4: the training modes, read training patterns,
// per-DRAM addressability, Vref shadowing and write preamble enforcement.
//
// The three loopback modes all work the same way from the host's side: put the
// DRAM in the mode, drive one signal, and read the answer back as a static
// level on DQ. What differs is which signal is being measured.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_ddr5_training;
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;

  localparam int  DQ_BITS  = 16;
  localparam int  BGW      = 2;
  localparam int  BAW      = 2;
  localparam int  ROW_BITS = 17;
  localparam int  COL_BITS = 10;
  localparam real TCK_PS   = 416.7;
  localparam int  RL_TGT   = 40;
  localparam int  WL_TGT   = RL_TGT - 2;

  logic                  CK_t, CK_c, CS_n, RESET_n;
  logic [CA_BITS-1:0]    CA;
  wire  [DQ_BITS-1:0]    DQ;
  wire                   DQS_t, DQS_c;
  logic [DQ_BITS/8-1:0]  DM_n;
  wire                   ALERT_n;

  logic                  tb_dq_en, tb_dqs_en, tb_dqs;
  logic [DQ_BITS-1:0]    tb_dq;
  assign DQ    = tb_dq_en  ? tb_dq   : {DQ_BITS{1'bz}};
  assign DQS_t = tb_dqs_en ? tb_dqs  : 1'bz;
  assign DQS_c = tb_dqs_en ? ~tb_dqs : 1'bz;

  int ck, fails, base;

  ddr5_device #(
    .DQ_BITS(DQ_BITS), .BG_BITS(BGW), .BA_BITS(BAW),
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
    .SPEED_BIN(BIN_DDR5_4800B), .DENSITY(DEN_32G),
    .CHECK(1'b1), .VERBOSE(1'b0), .DEV_NAME("U_DRAM"), .INIT_FAST(1'b1)
  ) dut (
    .CK_t(CK_t), .CK_c(CK_c), .CS_n(CS_n), .CA(CA), .RESET_n(RESET_n),
    .DQ(DQ), .DQS_t(DQS_t), .DQS_c(DQS_c), .DM_n(DM_n), .ALERT_n(ALERT_n)
  );

  initial begin CK_t = 1'b0; forever #(TCK_PS/2.0) CK_t = ~CK_t; end
  assign CK_c = ~CK_t;
  always @(posedge CK_t) ck <= ck + 1;

  task automatic ca_cycle(input logic cs, input logic [CA_BITS-1:0] v);
    @(negedge CK_t); CS_n = cs; CA = v;
  endtask
  task automatic idle(input int n);
    for (int i = 0; i < n; i++) ca_cycle(1'b1, '0);
  endtask
  task automatic c1(input logic [CA_BITS-1:0] v);
    ca_cycle(1'b0, v); ca_cycle(1'b1, '0);
  endtask
  task automatic mpc(input logic [7:0] op); c1(enc_mpc(op)); endtask
  task automatic mrw(input logic [7:0] a, input logic [7:0] op);
    ca_cycle(1'b0, enc_mrw1(a));
    ca_cycle(1'b1, enc_mrw2(op));
    ca_cycle(1'b1, '0);
    idle(30);
  endtask
  task automatic act(input int bg, input int ba, input int row);
    ca_cycle(1'b0, enc_act1(bg, ba, row, BGW, BAW));
    ca_cycle(1'b1, enc_act2(row, ROW_BITS));
    ca_cycle(1'b1, '0);
  endtask

  task automatic dram_init();
    idle(70);
    mpc(8'b1000_0000);
    idle(8);
    mpc(MPC_DLL_RESET);
    idle(8);
    mpc(MPC_ZQCAL_START);
    idle(2500);
    mpc(MPC_ZQCAL_LATCH);
    idle(80);
  endtask

  task automatic chk_pass(input string what, input bit ok);
    if (ok) $display("PASS: %s", what);
    else begin $display("FAIL: %s", what); fails++; end
  endtask

  // Sample a training loopback value: one CS_n assertion, then read DQ once
  // the pseudo-static output has settled.
  task automatic catm_sample(input logic [CA_BITS-1:0] v, output logic got);
    ca_cycle(1'b0, v);
    ca_cycle(1'b1, '0);
    #(TCK_PS/2.0);
    got = DQ[0];
  endtask

  logic got, exp;
  logic [DQ_BITS-1:0] rdpat [16];

  initial begin
    fails = 0; ck = 0; CS_n = 1'b1; CA = '0; DM_n = '1;
    tb_dq_en = 0; tb_dqs_en = 0; tb_dqs = 0; tb_dq = '0;
    RESET_n = 1'b0;
    repeat (10) @(posedge CK_t);
    RESET_n = 1'b1;
    dram_init();
    mrw(8'd0, {1'b0, rl_to_mr0(RL_TGT), BL_BL16});

    // =====================================================================
    // A. MR2 bit map: 2N mode is OP[2], not OP[1]
    // =====================================================================
    mpc(MPC_SET_2N);
    idle(10);
    chk_pass("MPC Set 2N sets MR2 OP[2]",
             dut.mr[2][2] === 1'b1 && dut.mr[2][1] === 1'b0);
    mpc(MPC_SET_1N);
    idle(10);

    // =====================================================================
    // B. CA Training Mode: DQ carries XOR of the CA bus (Table 313)
    // =====================================================================
    mpc(MPC_ENTER_CA_TRAIN);
    idle(10);

    catm_sample(14'h0001, got);        // odd parity -> 1
    chk_pass("CATM loops back XOR(CA)=1 for a single set bit", got === 1'b1);
    idle(6);

    catm_sample(14'h0003, got);        // even parity -> 0
    chk_pass("CATM loops back XOR(CA)=0 for two set bits", got === 1'b0);
    idle(6);

    catm_sample(14'h2A55, got);
    exp = ^(14'h2A55);
    chk_pass("CATM loops back XOR(CA) for an arbitrary pattern", got === exp);

    // CS_n assertions must be 4 tCK or more apart (4.19.3).
    base = dut.error_count();
    catm_sample(14'h0001, got);
    idle(1);
    catm_sample(14'h0002, got);        // only ~3 tCK later
    idle(8);
    chk_pass("CATM rejects CS_n assertions closer than 4 tCK",
             dut.error_count() > base);

    // Two consecutive CS_n low cycles exit the mode.
    idle(8);
    ca_cycle(1'b0, '0);
    ca_cycle(1'b0, '0);
    ca_cycle(1'b1, '0);
    idle(10);
    chk_pass("CATM exits on 2 consecutive CS_n assertions and restores state",
             dut.device_state() == int'(DS_NORMAL));

    // =====================================================================
    // C. CS Training Mode: pairs of CS_n samples, evaluated then ORed
    // =====================================================================
    mpc(MPC_ENTER_CS_TRAIN);
    // The sampler restarts its group of four on entry, and the second cycle of
    // the MPC plus three idles consume exactly one group, so the pattern below
    // starts aligned.
    idle(3);

    // Sample pair (0,1) is the only combination giving an intermediate 0, so
    // all four samples must be 0,1,0,1 for the final output to be 0. CS_n is
    // asserted with a NOP: the DRAM still decodes commands in CS training.
    ca_cycle(1'b0, enc_nop());
    ca_cycle(1'b1, '0);
    ca_cycle(1'b0, enc_nop());
    ca_cycle(1'b1, '0);
    #(TCK_PS*0.75);
    chk_pass("CSTM drives 0 for the sample sequence 0,1,0,1", DQ[0] === 1'b0);

    ca_cycle(1'b1, '0);
    ca_cycle(1'b1, '0);
    ca_cycle(1'b1, '0);
    ca_cycle(1'b1, '0);
    #(TCK_PS*0.75);
    chk_pass("CSTM drives 1 when CS_n stays high", DQ[0] === 1'b1);

    mpc(MPC_EXIT_CS_TRAIN);
    idle(10);
    chk_pass("CSTM exit restores the previous state",
             dut.device_state() == int'(DS_NORMAL));

    // =====================================================================
    // D. Write levelling: DQ reports CK_t sampled on the rising edge of DQS
    // =====================================================================
    mrw(8'd2, 8'b0000_0010);           // MR2 OP[1] = 1
    idle(10);

    // Place a DQS rising edge while CK_t is high.
    @(posedge CK_t);
    tb_dqs = 1'b0; tb_dqs_en = 1'b1;
    #(TCK_PS/4.0);
    tb_dqs = 1'b1;
    #(TCK_PS/8.0);
    chk_pass("write levelling reports CK_t high", DQ[0] === 1'b1);

    @(negedge CK_t);
    tb_dqs = 1'b0;
    #(TCK_PS/4.0);
    tb_dqs = 1'b1;                     // rising edge while CK_t is low
    #(TCK_PS/8.0);
    chk_pass("write levelling reports CK_t low", DQ[0] === 1'b0);
    tb_dqs_en = 1'b0;

    mrw(8'd2, 8'b0000_0000);           // leave write levelling
    idle(20);

    // =====================================================================
    // E. Read training pattern: MRR to MR31 returns a BL16 pattern
    // =====================================================================
    begin
      int k;
      logic [7:0] d0, d1;
      d0 = 8'h5A; d1 = 8'h3C;          // MR26 / MR27 power-on defaults
      @(negedge CK_t);
      k = ck;
      CS_n = 1'b0; CA = enc_mrr1(8'd31);
      @(negedge CK_t);
      CS_n = 1'b1; CA = enc_mrr2();
      @(negedge CK_t);
      CA = '0;
      while (ck < k + RL_TGT) @(negedge CK_t);
      #(TCK_PS*0.75);
      for (int b = 0; b < 16; b++) begin
        rdpat[b] = DQ;
        #(TCK_PS/2.0);
      end
      got = 1'b1;
      for (int b = 0; b < 16; b++) begin
        exp = (b < 8) ? d0[7-b] : d1[7-(b-8)];
        if (rdpat[b] !== {DQ_BITS{exp}}) got = 1'b0;
      end
      chk_pass("MRR to MR31 returns the serial read training pattern", got);
    end
    idle(30);

    // =====================================================================
    // F. Per DRAM Addressability: an MRW only lands on the selected device
    // =====================================================================
    mpc(MPC_ENTER_PDA_ENUM);
    idle(8);
    mpc(8'b0110_0011);                 // PDA Enumerate ID = 3
    idle(8);
    mpc(MPC_EXIT_PDA_ENUM);
    idle(8);
    chk_pass("PDA enumerate ID programmed", dut.pda_id() === 4'd3);

    mpc(8'b0111_0101);                 // PDA Select ID = 5 : not this device
    idle(8);
    mrw(8'd28, 8'hAA);
    chk_pass("MRW ignored while another PDA ID is selected",
             dut.mr[28] !== 8'hAA);

    mpc(8'b0111_0011);                 // PDA Select ID = 3 : this device
    idle(8);
    mrw(8'd28, 8'hAA);
    chk_pass("MRW applied once this device's PDA ID is selected",
             dut.mr[28] === 8'hAA);

    mpc(8'b0111_1111);                 // back to broadcast
    idle(8);
    mrw(8'd28, 8'h00);

    // =====================================================================
    // G. Vref shadowing: the VrefCA command does not take effect until the
    //    MPC Apply commits it (Table 290 NOTE 8)
    // =====================================================================
    c1(enc_vrefca(7'h55));
    idle(10);
    chk_pass("VrefCA sits in the shadow register until applied",
             dut.mr[11] !== 8'h55);
    mpc(MPC_APPLY_VREF_RTT);
    idle(10);
    chk_pass("MPC Apply commits VrefCA into MR11", dut.mr[11] === 8'h55);

    // =====================================================================
    // H. Write preamble: too short a DQS lead is a tWPRE violation
    // =====================================================================
    c1(enc_pre_ab());
    idle(50);
    act(0, 0, 17'h0);
    idle(45);
    begin
      int k;
      @(negedge CK_t);
      k = ck;
      CS_n = 1'b0; CA = enc_cas1(1'b0, 0, 0, 1'b1, BGW, BAW);
      @(negedge CK_t);
      CS_n = 1'b1; CA = enc_cas2(1'b0, 11'h000, 1'b0);
      @(negedge CK_t);
      CA = '0;
      base = dut.error_count();
      // Start DQS only 1 tCK ahead of the burst; MR8 asks for 2.
      while (ck < k + WL_TGT - 1) @(negedge CK_t);
      tb_dqs = 1'b0; tb_dqs_en = 1'b1;   // driven over posedge k+WL only
      #(TCK_PS*1.5);                     // beat 0 at posedge k+WL+1
      tb_dq_en = 1'b1;
      for (int b = 0; b < 16; b++) begin
        tb_dq = 16'(b);
        #(TCK_PS/4.0);
        tb_dqs = ~tb_dqs;
        #(TCK_PS/4.0);
      end
      tb_dq_en = 1'b0; tb_dqs_en = 1'b0;
      idle(20);
      chk_pass("short write preamble reported as tWPRE",
               dut.error_count() > base);
    end

    idle(40);
    $display("=== tb_ddr5_training: %0d failures ===", fails);
    if (fails == 0) $display("=== TRAINING TEST PASSED ===");
    else            $display("=== TRAINING TEST FAILED ===");
    $finish;
  end

  initial begin
    #60_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
