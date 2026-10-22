// ---------------------------------------------------------------------------
// tb_ddr5_refresh.sv — Stage 2 checks: initialisation, refresh management,
// tREFI, power states and ZQ calibration windows.
//
// Mostly negative tests. Each sub-test records the device's error count, does
// something a controller might plausibly get wrong, and asserts that the model
// noticed -- and, just as importantly, that the legal cases produce nothing.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_ddr5_refresh;
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;

  localparam int  DQ_BITS  = 16;
  localparam int  BGW      = 2;
  localparam int  BAW      = 2;
  localparam int  ROW_BITS = 17;
  localparam int  COL_BITS = 10;
  localparam real TCK_PS   = 416.7;

  // Small RFM thresholds so the RAAMMT ceiling is reachable in a sane runtime:
  // RAAIMT code 0100B = 32, RAAMMT code 011B = 3x => 96.
  localparam logic [3:0] RAAIMT_CODE = 4'b0100;
  localparam logic [2:0] RAAMMT_CODE = 3'b011;
  localparam int         RAAIMT      = 32;
  localparam int         RAAMMT      = 96;

  logic                  CK_t, CK_c, CS_n, RESET_n;
  logic [CA_BITS-1:0]    CA;
  wire  [DQ_BITS-1:0]    DQ;
  wire                   DQS_t, DQS_c;
  logic [DQ_BITS/8-1:0]  DM_n;
  wire                   ALERT_n;

  int ck, fails, base;

  ddr5_device #(
    .DQ_BITS(DQ_BITS), .BG_BITS(BGW), .BA_BITS(BAW),
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
    .SPEED_BIN(BIN_DDR5_4800B), .DENSITY(DEN_32G),
    .CHECK(1'b1), .VERBOSE(1'b0), .DEV_NAME("U_DRAM"),
    .INIT_FAST(1'b1), .RFM_REQUIRED(1'b1),
    .RAAIMT_CODE(RAAIMT_CODE), .RAAMMT_CODE(RAAMMT_CODE), .RAADEC_CODE(2'b00)
  ) dut (
    .CK_t(CK_t), .CK_c(CK_c), .CS_n(CS_n), .CA(CA), .RESET_n(RESET_n),
    .DQ(DQ), .DQS_t(DQS_t), .DQS_c(DQS_c), .DM_n(DM_n), .ALERT_n(ALERT_n)
  );

  initial begin CK_t = 1'b0; forever #(TCK_PS/2.0) CK_t = ~CK_t; end
  assign CK_c = ~CK_t;
  always @(posedge CK_t) ck <= ck + 1;

  // ---- CA drive ----
  task automatic ca_cycle(input logic cs, input logic [CA_BITS-1:0] v);
    @(negedge CK_t); CS_n = cs; CA = v;
  endtask
  task automatic idle(input int n);
    for (int i = 0; i < n; i++) ca_cycle(1'b1, '0);
  endtask
  task automatic c1(input logic [CA_BITS-1:0] v);
    ca_cycle(1'b0, v); ca_cycle(1'b1, '0);
  endtask
  task automatic c2(input logic [CA_BITS-1:0] a,
                    input logic [CA_BITS-1:0] b);
    ca_cycle(1'b0, a); ca_cycle(1'b1, b); ca_cycle(1'b1, '0);
  endtask

  task automatic mpc(input logic [7:0] op); c1(enc_mpc(op)); endtask
  task automatic act(input int bg, input int ba, input int row);
    c2(enc_act1(bg, ba, row, BGW, BAW), enc_act2(row, ROW_BITS));
  endtask
  task automatic pre_pb(input int bg, input int ba);
    c1(enc_pre_pb(bg, ba, BGW, BAW));
  endtask

  // RFMab shares the REF encoding with CA9 low (4.41).
  function automatic logic [CA_BITS-1:0] enc_rfm_ab();
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b0;  c[3] = 1'b0;  c[4] = 1'b1;   // sel = REF/RFM
    c[9]  = 1'b0;                              // CA9  = L : management
    c[10] = 1'b0;                              // CA10 = L : all bank
    return c;
  endfunction

  task automatic device_reset();
    RESET_n = 1'b0;
    idle(8);
    RESET_n = 1'b1;
    idle(2);
  endtask

  task automatic dram_init();
    idle(70);
    mpc(8'b1000_0000);        // MR13 tDLLK / tCCD_L
    idle(8);
    mpc(MPC_DLL_RESET);
    idle(8);
    mpc(MPC_ZQCAL_START);
    idle(2500);               // tZQCAL = 1 us
    mpc(MPC_ZQCAL_LATCH);
    idle(80);                 // tZQLAT
  endtask

  task automatic expect_errors(input string what, input int n_min);
    int got;
    got = dut.error_count() - base;
    if (got >= n_min)
      $display("PASS: %s -- caught %0d error(s)", what, got);
    else begin
      $display("FAIL: %s -- expected at least %0d error(s), got %0d",
               what, n_min, got);
      fails++;
    end
    base = dut.error_count();
  endtask

  task automatic expect_clean(input string what);
    int got;
    got = dut.error_count() - base;
    if (got == 0) $display("PASS: %s -- clean", what);
    else begin
      $display("FAIL: %s -- %0d unexpected error(s)", what, got);
      fails++;
    end
    base = dut.error_count();
  endtask

  initial begin
    fails = 0; ck = 0; CS_n = 1'b1; CA = '0; DM_n = '1; RESET_n = 1'b0;
    repeat (10) @(posedge CK_t);

    // =====================================================================
    // A. Initialisation ordering (3.3.1 step 7)
    // =====================================================================
    device_reset();
    idle(70);
    base = dut.error_count();
    mpc(MPC_ZQCAL_START);          // no MR13, no DLL RESET first
    idle(20);
    expect_errors("ZQCal Start before DLL RESET", 1);

    idle(20);
    base = dut.error_count();
    act(0, 0, 17'h10);             // ACT while still configuring
    idle(20);
    expect_errors("ACT during initialisation", 1);

    // =====================================================================
    // B. A correct initialisation must be silent
    // =====================================================================
    device_reset();
    base = dut.error_count();
    dram_init();
    expect_clean("full initialisation sequence");

    // Program BL16 / RL40 so later CAS timings are the 4800B ones.
    c2(enc_mrw1(8'd0), enc_mrw2({1'b0, rl_to_mr0(40), BL_BL16}));
    idle(40);

    // =====================================================================
    // C. ZQ calibration windows (4.23.1)
    // =====================================================================
    base = dut.error_count();
    mpc(MPC_ZQCAL_START);
    idle(50);
    mpc(MPC_ZQCAL_START);          // still inside tZQCAL
    idle(20);
    expect_errors("second ZQCal Start inside tZQCAL", 1);
    idle(2600);
    mpc(MPC_ZQCAL_LATCH);
    idle(10);
    base = dut.error_count();
    act(0, 0, 17'h20);             // CA must stay deselect through tZQLAT
    idle(20);
    expect_errors("command during tZQLAT", 1);
    idle(120);

    // =====================================================================
    // D. Refresh management: RAA counters (4.41)
    //
    // Each ACT adds one to the bank's RAA. At RAAMMT no further ACT to that
    // bank is legal until a REF or RFM brings the count down.
    // =====================================================================
    base = dut.error_count();
    for (int i = 0; i < RAAMMT; i++) begin
      act(0, 0, 17'h100 + i);
      idle(80);                    // > tRAS (77)
      pre_pb(0, 0);
      idle(45);                    // > tRP (39), and > tRC (116) across the pair
    end
    expect_clean($sformatf("%0d ACTs up to RAAMMT", RAAMMT));

    act(0, 0, 17'h200);            // one past the ceiling
    idle(80);
    pre_pb(0, 0);
    idle(45);
    expect_errors("ACT at RAAMMT with no intervening REF/RFM", 1);

    // RFMab decrements every bank by RAAIMT, which reopens the bank.
    c1(enc_rfm_ab());
    idle(760);                     // tRFM1 = tRFC1 = 709 nCK
    base = dut.error_count();
    for (int i = 0; i < 4; i++) begin
      act(0, 0, 17'h300 + i);
      idle(80);
      pre_pb(0, 0);
      idle(45);
    end
    expect_clean("ACTs resume after RFMab decrements RAA");

    // =====================================================================
    // E. Power down (PDE / PDX) and tXP
    // =====================================================================
    base = dut.error_count();
    c1(enc_pre_ab());
    idle(50);
    c1(enc_pde());
    idle(20);
    act(0, 0, 17'h400);            // illegal: only PDX exits power-down
    idle(20);
    expect_errors("command issued in power-down", 1);

    c1(enc_nop());                 // NOP decodes as PDX while powered down
    base = dut.error_count();
    act(0, 0, 17'h401);            // immediately after exit: tXP not met
    idle(20);
    expect_errors("command inside tXP after power-down exit", 1);
    idle(60);
    pre_pb(0, 0);
    idle(70);

    // =====================================================================
    // F. Self refresh (SRE) and tXS
    // =====================================================================
    base = dut.error_count();
    act(0, 0, 17'h500);            // leave a row open on purpose
    idle(90);
    c1(enc_sre());                 // illegal: banks must be precharged
    idle(20);
    expect_errors("SRE with an open bank", 1);

    c1(enc_pre_ab());
    idle(60);
    base = dut.error_count();
    c1(enc_sre());
    idle(40);
    c1(enc_nop());                 // any CS_n assertion is the exit
    act(0, 0, 17'h501);            // immediately after: tXS not met
    idle(20);
    expect_errors("command inside tXS after self-refresh exit", 1);
    idle(800);
    pre_pb(0, 0);
    idle(70);

    // =====================================================================
    // G. tREFI. The gap between two REFab may stretch to 5 x tREFI, no more.
    // =====================================================================
    c1(enc_pre_ab());
    idle(50);
    c1(enc_ref_ab());
    idle(760);
    base = dut.error_count();
    idle(4000);
    expect_clean("idle well inside the 5 x tREFI window");

    idle(46000);                   // now past 5 x tREFI (9360 nCK each)
    expect_errors("REFab interval stretched past 5 x tREFI", 1);

    $display("=== tb_ddr5_refresh: %0d failures ===", fails);
    if (fails == 0) $display("=== REFRESH/POWER TEST PASSED ===");
    else            $display("=== REFRESH/POWER TEST FAILED ===");
    $finish;
  end

  initial begin
    #400_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
