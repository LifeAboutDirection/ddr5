// ---------------------------------------------------------------------------
// tb_ddr5_smoke.sv — Stage 1 smoke test for ddr5_device
//
// Drives the CA bus at pin level exactly as JESD79-5 Table 241 specifies:
//   MRW  -> program MR0 for RL=40 / BL16
//   ACT  -> open a row
//   WR   -> BL16 write with a walking pattern
//   RD   -> read it back and compare on DQ
//   PRE  -> close the row
// Then deliberately violates tRCD to prove the checker fires.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_ddr5_smoke;
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;

  localparam int  DQ_BITS  = 16;
  localparam int  BG_BITS  = 2;
  localparam int  BA_BITS  = 2;
  localparam int  ROW_BITS = 17;
  localparam int  COL_BITS = 10;
  localparam real TCK_PS   = 416.7;      // DDR5-4800B

  localparam int  RL_TGT   = 40;
  localparam int  WL_TGT   = RL_TGT - 2;

  logic                   CK_t, CK_c;
  logic                   CS_n;
  logic [CA_BITS-1:0]     CA;
  logic                   RESET_n;
  wire  [DQ_BITS-1:0]     DQ;
  wire                    DQS_t, DQS_c;
  logic [DQ_BITS/8-1:0]   DM_n;
  wire                    ALERT_n;

  // TB-side DQ / DQS drivers (write data). DDR5 write DQS is centre-aligned to
  // DQ: DQ changes on the beat boundary, DQS strobes in the middle of the beat.
  logic                   tb_dq_en;
  logic [DQ_BITS-1:0]     tb_dq;
  logic                   tb_dqs_en;
  logic                   tb_dqs;
  assign DQ    = tb_dq_en  ? tb_dq  : {DQ_BITS{1'bz}};
  assign DQS_t = tb_dqs_en ? tb_dqs : 1'bz;
  assign DQS_c = tb_dqs_en ? ~tb_dqs : 1'bz;

  int ck;                               // TB's own cycle counter
  int fails;

  ddr5_device #(
    .DQ_BITS (DQ_BITS), .BG_BITS (BG_BITS), .BA_BITS (BA_BITS),
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
    .SPEED_BIN(BIN_DDR5_4800B), .DENSITY(DEN_32G),
    .CHECK(1'b1), .VERBOSE(1'b1), .DEV_NAME("U_DRAM")
  ) dut (
    .CK_t(CK_t), .CK_c(CK_c), .CS_n(CS_n), .CA(CA), .RESET_n(RESET_n),
    .DQ(DQ), .DQS_t(DQS_t), .DQS_c(DQS_c), .DM_n(DM_n), .ALERT_n(ALERT_n)
  );

  // ---- clock ----
  initial begin
    CK_t = 1'b0;
    forever #(TCK_PS/2.0) CK_t = ~CK_t;
  end
  assign CK_c = ~CK_t;

  always @(posedge CK_t) ck <= ck + 1;

  // -------------------------------------------------------------------------
  // CA drive helpers. Values are set on the falling edge so they are stable
  // at the rising edge the DRAM samples on.
  // -------------------------------------------------------------------------
  task automatic ca_cycle(input logic cs, input logic [CA_BITS-1:0] ca_val);
    @(negedge CK_t);
    CS_n = cs;
    CA   = ca_val;
  endtask

  task automatic ca_idle(input int n);
    for (int i = 0; i < n; i++) ca_cycle(1'b1, '0);   // DES
  endtask

  task automatic cmd_mrw(input logic [7:0] mra, input logic [7:0] op);
    logic [CA_BITS-1:0] c1, c2;
    c1 = '0;
    c1[0] = 1'b1; c1[1] = 1'b0;                 // 2-cycle group
    c1[2] = 1'b1; c1[3] = 1'b0; c1[4] = 1'b0;   // sel = MRW
    c1[5 +: 8] = mra;
    c2 = '0;
    c2[0 +: 8] = op;
    c2[10] = 1'b0;                              // CW = L : execute
    ca_cycle(1'b0, c1);
    ca_cycle(1'b1, c2);
  endtask

  task automatic cmd_act(input int bg, input int ba, input int row);
    logic [CA_BITS-1:0] c1, c2;
    logic [ROW_BITS-1:0] r;
    r  = ROW_BITS'(row);
    c1 = '0;
    c1[0] = 1'b0; c1[1] = 1'b0;                 // ACT
    c1[5:2]        = r[3:0];
    c1[6 +: BA_BITS] = BA_BITS'(ba);
    c1[8 +: BG_BITS] = BG_BITS'(bg);
    c2 = '0;
    c2[ROW_BITS-5:0] = r[ROW_BITS-1:4];
    ca_cycle(1'b0, c1);
    ca_cycle(1'b1, c2);
  endtask

  // Edge anchoring, used by both burst tasks:
  //   at a negedge, `ck` == number of posedges elapsed. The first CA cycle of
  //   the command is therefore latched at posedge k+1, and JEDEC measures
  //   WL / RL from that cycle.
  task automatic cmd_wr_burst(input int bg, input int ba, input int col,
                              input bit ap,
                              input logic [DQ_BITS-1:0] pat [16]);
    logic [CA_BITS-1:0] c1, c2;
    logic [10:0] c;
    int k;
    c  = 11'(col);
    c1 = '0;
    c1[0] = 1'b1; c1[1] = 1'b0;
    c1[2] = 1'b1; c1[3] = 1'b1; c1[4] = 1'b0;   // sel = WR
    c1[5] = 1'b1;                               // BL* = H -> default BL16
    c1[6 +: BA_BITS] = BA_BITS'(ba);
    c1[8 +: BG_BITS] = BG_BITS'(bg);
    c2 = '0;
    c2[8:1] = c[10:3];                          // C10..C3
    c2[10]  = ap ? 1'b0 : 1'b1;                 // CA10 = AP (L = auto-pre)
    c2[11]  = 1'b1;                             // WR_partial = H (full write)

    @(negedge CK_t);
    k = ck;
    CS_n = 1'b0; CA = c1;
    @(negedge CK_t);
    CS_n = 1'b1; CA = c2;

    // The DRAM opens its capture window at posedge k+1+WL, which is where
    // beat 0 starts. Drive a 2 tCK DQS preamble first: those edges fall
    // outside the window and are ignored, exactly as tWPRE requires.
    while (ck < k + WL_TGT - 2) @(negedge CK_t);
    tb_dqs    = 1'b0;                           // preamble: DQS driven low
    tb_dqs_en = 1'b1;                           // over posedges k+WL-1, k+WL
    #(TCK_PS*2.5);                              // at posedge k+WL+1 = beat 0
    tb_dq_en  = 1'b1;
    for (int b = 0; b < 16; b++) begin
      tb_dq = pat[b];                           // DQ changes on the boundary
      #(TCK_PS/4.0);
      tb_dqs = ~tb_dqs;                         // DQS strobes at the centre
      #(TCK_PS/4.0);
    end
    tb_dq_en  = 1'b0;
    tb_dqs_en = 1'b0;
  endtask

  task automatic cmd_rd_burst(input int bg, input int ba, input int col,
                              input bit ap,
                              output logic [DQ_BITS-1:0] got [16]);
    logic [CA_BITS-1:0] c1, c2;
    logic [10:0] c;
    int k;
    c  = 11'(col);
    c1 = '0;
    c1[0] = 1'b1; c1[1] = 1'b0;
    c1[2] = 1'b1; c1[3] = 1'b1; c1[4] = 1'b1;   // sel = RD
    c1[5] = 1'b1;                               // BL* = H
    c1[6 +: BA_BITS] = BA_BITS'(ba);
    c1[8 +: BG_BITS] = BG_BITS'(bg);
    c2 = '0;
    c2[8:0] = c[10:2];                          // C10..C2
    c2[10]  = ap ? 1'b0 : 1'b1;

    @(negedge CK_t);
    k = ck;
    CS_n = 1'b0; CA = c1;
    @(negedge CK_t);
    CS_n = 1'b1; CA = c2;

    // beat 0 appears on DQ at posedge k+1+RL; sample a quarter cycle after it
    while (ck < k + RL_TGT) @(negedge CK_t);
    #(TCK_PS*0.75);
    for (int b = 0; b < 16; b++) begin
      got[b] = DQ;
      #(TCK_PS/2.0);
    end
  endtask

  task automatic cmd_pre_pb(input int bg, input int ba);
    logic [CA_BITS-1:0] c1;
    c1 = '0;
    c1[0] = 1'b1; c1[1] = 1'b1;                 // 1-cycle group
    c1[2] = 1'b0; c1[3] = 1'b1; c1[4] = 1'b1;   // sel = PREpb
    c1[6 +: BA_BITS] = BA_BITS'(ba);
    c1[8 +: BG_BITS] = BG_BITS'(bg);
    ca_cycle(1'b0, c1);
  endtask

  task automatic cmd_mpc(input logic [7:0] op);
    ca_cycle(1'b0, enc_mpc(op));
  endtask

  // JESD79-5 3.3.1 step 7: the configuration MPCs must run in this order
  // before the part will leave initialisation.
  //   MR13 (tDLLK/tCCD_L) -> DLL RESET -> ZQCal Start -> ZQCal Latch
  task automatic dram_init();
    ca_idle(70);                       // clear the init / tXPR window
    cmd_mpc(8'b1000_0000);             // configure tDLLK / tCCD_L into MR13
    ca_idle(8);
    cmd_mpc(MPC_DLL_RESET);
    ca_idle(8);
    cmd_mpc(MPC_ZQCAL_START);
    ca_idle(2500);                     // tZQCAL is 1 us
    cmd_mpc(MPC_ZQCAL_LATCH);
    ca_idle(80);                       // tZQLAT = max(30 ns, 8 nCK) = 72 nCK
  endtask

  task automatic cmd_refab();
    logic [CA_BITS-1:0] c1;
    c1 = '0;
    c1[0] = 1'b1; c1[1] = 1'b1;
    c1[2] = 1'b0; c1[3] = 1'b0; c1[4] = 1'b1;   // sel = REF/RFM
    c1[9]  = 1'b1;                              // CA9 = H -> Refresh
    c1[10] = 1'b0;                              // CA10 = L -> all bank
    ca_cycle(1'b0, c1);
  endtask

  // -------------------------------------------------------------------------
  // Test body
  // -------------------------------------------------------------------------
  logic [DQ_BITS-1:0] pat [16];
  logic [DQ_BITS-1:0] got [16];
  int base_err;

  initial begin
    fails    = 0;
    ck       = 0;
    CS_n     = 1'b1;
    CA       = '0;
    DM_n     = '1;
    tb_dq_en  = 1'b0;
    tb_dq     = '0;
    tb_dqs_en = 1'b0;
    tb_dqs    = 1'b0;
    RESET_n   = 1'b0;

    repeat (10) @(posedge CK_t);
    RESET_n = 1'b1;
    dram_init();

    // ---- 1. program MR0: BL16 (OP[1:0]=00), RL=40 (OP[6:2]=9) ----
    $display("--- MRW MR0: BL16, RL=%0d ---", RL_TGT);
    cmd_mrw(8'd0, {1'b0, rl_to_mr0(RL_TGT), BL_BL16});
    ca_idle(40);

    // ---- 2. ACT ----
    $display("--- ACT bg0 ba0 row 0x1234 ---");
    cmd_act(0, 0, 17'h1234);
    ca_idle(45);                       // > tRCD (39)

    // ---- 3. WR BL16 ----
    $display("--- WR col 0x040 ---");
    for (int i = 0; i < 16; i++) pat[i] = 16'hA000 + 16'(i);
    cmd_wr_burst(0, 0, 11'h040, 1'b0, pat);
    ca_idle(90);                       // clear tWTR_L and the data burst

    // ---- 4. RD BL16 and compare ----
    $display("--- RD col 0x040 ---");
    cmd_rd_burst(0, 0, 11'h040, 1'b0, got);
    for (int i = 0; i < 16; i++) begin
      if (got[i] !== pat[i]) begin
        $display("MISMATCH beat %0d: expected %04h got %04h",
                 i, pat[i], got[i]);
        fails++;
      end
    end
    if (fails == 0) $display("PASS: BL16 write/read data matched on DQ");

    // ---- 5. backdoor cross-check of the array ----
    for (int i = 0; i < 16; i++) begin
      logic [DQ_BITS-1:0] v;
      v = dut.backdoor_read(0, 17'h1234, 11'h040 + i);
      if (v !== pat[i]) begin
        $display("BACKDOOR MISMATCH col %0d: expected %04h got %04h",
                 11'h040 + i, pat[i], v);
        fails++;
      end
    end

    ca_idle(60);
    cmd_pre_pb(0, 0);
    ca_idle(45);

    // ---- 6. negative test: ACT then CAS before tRCD ----
    base_err = dut.error_count();
    $display("--- negative test: RD %0d nCK after ACT (tRCD=%0d) ---",
             10, 39);
    cmd_act(1, 0, 17'h0055);
    ca_idle(6);                        // ~10 nCK total, well under tRCD
    cmd_rd_burst(1, 0, 11'h000, 1'b0, got);
    ca_idle(10);
    if (dut.error_count() > base_err)
      $display("PASS: tRCD violation was caught (%0d new errors)",
               dut.error_count() - base_err);
    else begin
      $display("FAIL: tRCD violation was NOT caught");
      fails++;
    end

    ca_idle(200);
    $display("=== tb_ddr5_smoke: %0d functional failures ===", fails);
    if (fails == 0) $display("=== SMOKE TEST PASSED ===");
    else            $display("=== SMOKE TEST FAILED ===");
    $finish;
  end

  initial begin
    #40_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
