// ---------------------------------------------------------------------------
// tb_ddr5_ecc.sv — Stage 3: on-die ECC, ECS scrub and write CRC.
//
// The interesting property of on-die ECC is that it is invisible: a controller
// reading a word with a single-bit error gets clean data back and no signal at
// all. These tests check that, check that a read does NOT repair the array
// (only ECS scrubs), and check that a bad write CRC does reach the controller
// through ALERT_n.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_ddr5_ecc;
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;
  import ddr5_ecc_pkg::*;

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
  bit alert_seen;

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
  always @(negedge ALERT_n) alert_seen <= 1'b1;

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
  task automatic mpc(input logic [7:0] op); c1(enc_mpc(op)); endtask
  task automatic act(input int bg, input int ba, input int row);
    ca_cycle(1'b0, enc_act1(bg, ba, row, BGW, BAW));
    ca_cycle(1'b1, enc_act2(row, ROW_BITS));
    ca_cycle(1'b1, '0);
  endtask
  task automatic pre_pb(input int bg, input int ba);
    c1(enc_pre_pb(bg, ba, BGW, BAW));
  endtask
  task automatic mrw(input logic [7:0] a, input logic [7:0] op);
    ca_cycle(1'b0, enc_mrw1(a));
    ca_cycle(1'b1, enc_mrw2(op));
    ca_cycle(1'b1, '0);
    idle(30);
  endtask

  // ---- CRC helpers, matching the device's stated bit convention ----
  function automatic logic [63:0] crc_data(input logic [DQ_BITS-1:0] b [16],
                                           input int nib);
    logic [63:0] d;
    d = '0;
    for (int beat = 0; beat < 16; beat++)
      for (int k = 0; k < 4; k++)
        d[63 - (beat*4 + k)] = b[beat][nib*4 + k];
    return d;
  endfunction

  // ---- write / read bursts ----
  task automatic wr_burst(input int bg, input int ba, input int col,
                          input logic [DQ_BITS-1:0] pat [16],
                          input bit with_crc, input bit corrupt_crc);
    int k, nbeats;
    logic [DQ_BITS-1:0] ui [18];
    logic [7:0] c;

    for (int i = 0; i < 16; i++) ui[i] = pat[i];
    ui[16] = '0;  ui[17] = '0;
    if (with_crc) begin
      for (int nib = 0; nib < DQ_BITS/4; nib++) begin
        c = crc8_d64(crc_data(pat, nib));
        if (corrupt_crc) c = c ^ 8'h01;
        for (int u = 0; u < 2; u++)
          for (int b = 0; b < 4; b++)
            ui[16+u][nib*4 + b] = c[7 - (u*4 + b)];
      end
    end
    nbeats = with_crc ? 18 : 16;

    @(negedge CK_t);
    k = ck;
    CS_n = 1'b0; CA = enc_cas1(1'b0, bg, ba, 1'b1, BGW, BAW);
    @(negedge CK_t);
    CS_n = 1'b1; CA = enc_cas2(1'b0, col, 1'b0);
    @(negedge CK_t);
    CA = '0;

    while (ck < k + WL_TGT - 2) @(negedge CK_t);
    tb_dqs = 1'b0; tb_dqs_en = 1'b1;          // preamble, two CK edges of it
    #(TCK_PS*2.5);
    tb_dq_en = 1'b1;
    for (int b = 0; b < nbeats; b++) begin
      tb_dq = ui[b];
      #(TCK_PS/4.0);
      tb_dqs = ~tb_dqs;
      #(TCK_PS/4.0);
    end
    tb_dq_en = 1'b0; tb_dqs_en = 1'b0;
  endtask

  task automatic rd_burst(input int bg, input int ba, input int col,
                          output logic [DQ_BITS-1:0] got [16]);
    int k;
    @(negedge CK_t);
    k = ck;
    CS_n = 1'b0; CA = enc_cas1(1'b1, bg, ba, 1'b1, BGW, BAW);
    @(negedge CK_t);
    CS_n = 1'b1; CA = enc_cas2(1'b1, col, 1'b0);
    @(negedge CK_t);
    CA = '0;
    while (ck < k + RL_TGT) @(negedge CK_t);
    #(TCK_PS*0.75);
    for (int b = 0; b < 16; b++) begin
      got[b] = DQ;
      #(TCK_PS/2.0);
    end
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

  logic [DQ_BITS-1:0] pat [16];
  logic [DQ_BITS-1:0] got [16];
  int ce0;
  bit ok;

  initial begin
    fails = 0; ck = 0; CS_n = 1'b1; CA = '0; DM_n = '1;
    tb_dq_en = 0; tb_dqs_en = 0; tb_dqs = 0; tb_dq = '0;
    alert_seen = 1'b0;
    RESET_n = 1'b0;
    repeat (10) @(posedge CK_t);
    RESET_n = 1'b1;
    dram_init();
    mrw(8'd0, {1'b0, rl_to_mr0(RL_TGT), BL_BL16});

    for (int i = 0; i < 16; i++) pat[i] = 16'h5A00 + 16'(i);

    // =====================================================================
    // A. Write a block, corrupt one bit, and read it back.
    //    The DRAM must return clean data and say nothing.
    // =====================================================================
    act(0, 0, 17'h0);
    idle(45);
    wr_burst(0, 0, 11'h000, pat, 1'b0, 1'b0);
    idle(90);

    ok = (dut.backdoor_read(0, 0, 11'h003) === pat[3]);
    chk_pass("write landed in the array", ok);

    ce0 = dut.ecc_corrected_count();
    dut.inject_bit_error(0, 0, 11'h003, 5);
    ok = (dut.backdoor_read(0, 0, 11'h003) !== pat[3]);
    chk_pass("injected bit error is present in the array", ok);

    rd_burst(0, 0, 11'h000, got);
    ok = 1'b1;
    for (int i = 0; i < 16; i++) if (got[i] !== pat[i]) ok = 1'b0;
    chk_pass("read returns ECC-corrected data despite the flipped bit", ok);
    chk_pass("the correction was counted",
             dut.ecc_corrected_count() > ce0);

    // 4.35: the DRAM shall not write corrected data back during a read.
    ok = (dut.backdoor_read(0, 0, 11'h003) !== pat[3]);
    chk_pass("read did NOT scrub the array (4.35)", ok);

    idle(60);
    pre_pb(0, 0);
    idle(50);

    // =====================================================================
    // B. ECS. Manual mode has to be enabled first, and the scrub must
    //    actually repair the array -- unlike a read.
    // =====================================================================
    base = dut.error_count();
    mpc(MPC_MANUAL_ECS);                 // MR14 OP[7] still 0
    idle(20);
    chk_pass("manual ECS rejected while MR14 OP[7]=0",
             dut.error_count() > base);

    mrw(8'd14, 8'b1000_0000);            // MR14 OP[7]=1: manual ECS mode
    base = dut.error_count();
    mpc(MPC_MANUAL_ECS);                 // scrubs bank 0 / row 0 / block 0
    idle(300);
    chk_pass("manual ECS accepted with manual mode enabled",
             dut.error_count() == base);
    ok = (dut.backdoor_read(0, 0, 11'h003) === pat[3]);
    chk_pass("ECS scrubbed the corrupted bit out of the array", ok);

    base = dut.error_count();
    mpc(MPC_MANUAL_ECS);
    idle(20);
    mpc(MPC_MANUAL_ECS);                 // inside tECSc
    idle(300);
    chk_pass("second ECS inside tECSc rejected", dut.error_count() > base);

    // =====================================================================
    // C. Write CRC. A correct CRC is silent; a bad one pulls ALERT_n.
    // =====================================================================
    idle(300);
    mrw(8'd50, 8'b0000_0110);            // MR50 OP[2:1]: write CRC, both nibbles
    act(0, 1, 17'h20);
    idle(45);

    alert_seen = 1'b0;
    base = dut.error_count();
    wr_burst(0, 1, 11'h000, pat, 1'b1, 1'b0);
    idle(120);
    chk_pass("correct write CRC is silent",
             (dut.error_count() == base) && !alert_seen);
    ok = (dut.backdoor_read(1, 17'h20, 11'h005) === pat[5]);
    chk_pass("CRC-protected write still landed in the array", ok);

    alert_seen = 1'b0;
    base = dut.error_count();
    wr_burst(0, 1, 11'h010, pat, 1'b1, 1'b1);
    idle(120);
    chk_pass("corrupted write CRC is reported", dut.error_count() > base);
    chk_pass("ALERT_n pulsed low on the CRC error", alert_seen);
    chk_pass("MR50 OP[3] write CRC error status set", dut.mr[50][3] === 1'b1);

    idle(60);
    $display("=== tb_ddr5_ecc: %0d failures ===", fails);
    if (fails == 0) $display("=== ECC/ECS/CRC DEVICE TEST PASSED ===");
    else            $display("=== ECC/ECS/CRC DEVICE TEST FAILED ===");
    $finish;
  end

  initial begin
    #60_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
