// ---------------------------------------------------------------------------
// tb_dfi_smoke.sv — DFI-level smoke test
//
// Stands in for the RMC exchange fabric: drives DFI 5.2 phases into
// dfi_ddr5_phy, which drives ddr5_device's pins. Nothing here touches DRAM
// pins directly, so a pass means the bridge, the latency arithmetic and the
// device all agree.
//
//   MRW MR0 -> ACT -> WR BL16 -> RD BL16 -> compare -> PREpb -> REFab
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_dfi_smoke #(
  parameter int G = 2                    // gear ratio; override with -GG=1|2|4
);
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;
  import dfi_pkg::*;

  localparam int  DQ_BITS  = 16;
  localparam int  N_CS     = 1;
  localparam int  BGW      = 2;          // BG field width for x16
  localparam int  BAW      = 2;
  localparam int  ROW_BITS = 17;
  localparam int  COL_BITS = 10;
  localparam real TCK_PS   = 416.7;

  localparam int  RL_TGT   = 40;         // DDR5-4800B, 40-39-39
  localparam int  WL_TGT   = RL_TGT - 2;

  localparam int  PH_DATA_W = 2*DQ_BITS;
  localparam int  PH_MASK_W = 2*(DQ_BITS/8);
  localparam int  GRPS      = 16/(2*G);  // dfi cycles per BL16 burst

  logic dfi_clk;
  int   t_phy_wrlat, t_phy_rdlat, t_rddata_en;

  dfi_if #(.G(G), .DQ_BITS(DQ_BITS), .CA_W(CA_BITS), .N_CS(N_CS))
    dfi (.dfi_clk(dfi_clk));

  wire                    CK_t, CK_c, CS_n, RESET_n;
  wire [CA_BITS-1:0]      CA;
  wire [DQ_BITS-1:0]      DQ;
  wire                    DQS_t, DQS_c;
  wire [(DQ_BITS/8)-1:0]  DM_n;
  wire                    ALERT_n;

  dfi_ddr5_phy #(
    .G(G), .DQ_BITS(DQ_BITS), .N_CS(N_CS), .TCK_PS(TCK_PS),
    .INIT_CK(64), .RL_INIT(22), .WL_INIT(20)
  ) u_phy (
    .dfi_clk(dfi_clk), .dfi(dfi),
    .t_phy_wrlat(t_phy_wrlat), .t_phy_rdlat(t_phy_rdlat),
    .t_rddata_en(t_rddata_en),
    .CK_t(CK_t), .CK_c(CK_c), .CS_n(CS_n), .CA(CA), .RESET_n(RESET_n),
    .DQ(DQ), .DQS_t(DQS_t), .DQS_c(DQS_c), .DM_n(DM_n)
  );

  ddr5_device #(
    .DQ_BITS(DQ_BITS), .BG_BITS(BGW), .BA_BITS(BAW),
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
    .SPEED_BIN(BIN_DDR5_4800B), .DENSITY(DEN_32G),
    .CHECK(1'b1), .VERBOSE(1'b1), .DEV_NAME("U_DRAM")
  ) u_dram (
    .CK_t(CK_t), .CK_c(CK_c), .CS_n(CS_n), .CA(CA), .RESET_n(RESET_n),
    .DQ(DQ), .DQS_t(DQS_t), .DQS_c(DQS_c), .DM_n(DM_n), .ALERT_n(ALERT_n)
  );

  int fails;

  // -------------------------------------------------------------------------
  // Read-return collector — what the fabric's RD-in path would do.
  // -------------------------------------------------------------------------
  logic [DQ_BITS-1:0] rd_q [$];

  always @(posedge dfi_clk) begin
    for (int p = 0; p < G; p++)
      if (dfi.rddata_valid[p])
        for (int h = 0; h < 2; h++)
          rd_q.push_back(dfi.rddata[(p*2+h)*DQ_BITS +: DQ_BITS]);
  end

  // -------------------------------------------------------------------------
  // Command emission. Everything is aligned to phase 0 of a dfi group, so a
  // two-cycle command lands on phases 0 and 1 -- which is the whole group at
  // G=2. Outputs are driven with nonblocking assignments, so the PHY samples
  // them on the following edge, as a synchronous controller would.
  // -------------------------------------------------------------------------
  task automatic drive_cmd1(input logic [CA_BITS-1:0] c1);
    @(posedge dfi_clk);
    dfi.address <= '0;
    dfi.cs      <= '0;
    dfi.address[0*CA_BITS +: CA_BITS] <= c1;
    dfi.cs[0]   <= 1'b1;
    @(posedge dfi_clk);
    dfi.cs      <= '0;
  endtask

  // At G >= 2 both CA cycles fit in one phase group. At G == 1 there is only
  // one phase per dfi cycle, so the second half carries into the next group --
  // the tail-carry case the fabric's phase packer has to handle.
  task automatic drive_cmd2(input logic [CA_BITS-1:0] c1,
                            input logic [CA_BITS-1:0] c2);
    @(posedge dfi_clk);
    dfi.address <= '0;
    dfi.cs      <= '0;
    dfi.address[0*CA_BITS +: CA_BITS] <= c1;
    dfi.cs[0]   <= 1'b1;                     // CS_n low on cycle 1
    if (G > 1) begin
      dfi.address[1*CA_BITS +: CA_BITS] <= c2;
      dfi.cs[1]   <= 1'b0;                   // CS_n high on cycle 2
      @(posedge dfi_clk);
      dfi.cs      <= '0;
    end
    else begin
      @(posedge dfi_clk);
      dfi.address[0*CA_BITS +: CA_BITS] <= c2;
      dfi.cs[0]   <= 1'b0;
      @(posedge dfi_clk);
      dfi.cs      <= '0;
    end
  endtask

  // Waits expressed in DRAM cycles. A dfi cycle is G tCK, so an idle counted
  // in dfi cycles shrinks with the gear ratio -- at 1:1 that silently turned a
  // tRCD wait into a tRCD violation.
  task automatic idle_tck(input int n);
    idle_dfi((n + G - 1)/G + 1);
  endtask

  task automatic idle_dfi(input int n);
    repeat (n) begin
      @(posedge dfi_clk);
      dfi.cs <= '0;
    end
  endtask

  // -------------------------------------------------------------------------
  // WR: emit the CA phases, then present the burst t_phy_wrlat dfi cycles
  // later, which is where dfi_pkg's latency arithmetic puts it for phase 0.
  // -------------------------------------------------------------------------
  task automatic dfi_write_burst(input int bg, input int ba, input int col,
                                 input bit ap,
                                 input logic [DQ_BITS-1:0] pat [16]);
    int qs, nslots, ngrp, si;
    logic [G-1:0]           en_v;
    logic [G*PH_DATA_W-1:0] d_v;

    drive_cmd2(enc_cas1(1'b0, bg, ba, 1'b1, BGW, BAW),
               enc_cas2(1'b0, col, ap));

    // Beat 0 belongs at (CA slot + WL). Splitting that into a dfi cycle and a
    // phase is the whole point of lat_cycles / lat_phase: at G=4 with WL=38,
    // WL/G is 9 but WL%G is 2, so the burst starts on phase 2, not phase 0.
    // Ignoring the phase term puts the data two tCK early and the DRAM
    // captures the tail of it.
    qs     = lat_phase(0, WL_TGT, G);
    nslots = 16/2;
    ngrp   = (qs + nslots + G - 1) / G;

    repeat (t_phy_wrlat - (G > 1 ? 2 : 3)) @(posedge dfi_clk);
    for (int c = 0; c < ngrp; c++) begin
      en_v = '0;
      d_v  = '0;
      for (int p = 0; p < G; p++) begin
        si = c*G + p - qs;
        if (si >= 0 && si < nslots) begin
          en_v[p] = 1'b1;
          for (int h = 0; h < 2; h++)
            d_v[(p*2+h)*DQ_BITS +: DQ_BITS] = pat[si*2 + h];
        end
      end
      @(posedge dfi_clk);
      dfi.wrdata_en   <= en_v;
      dfi.wrdata      <= d_v;
      dfi.wrdata_mask <= '0;                 // nothing masked
    end
    @(posedge dfi_clk);
    dfi.wrdata_en <= '0;
  endtask

  // -------------------------------------------------------------------------
  // RD: emit the CA phases, open the capture window at t_rddata_en, then let
  // the collector pick the burst up off dfi_rddata_valid.
  // -------------------------------------------------------------------------
  task automatic dfi_read_burst(input int bg, input int ba, input int col,
                                input bit ap);
    int qs, nslots, ngrp, si;
    logic [G-1:0] en_v;

    rd_q.delete();
    drive_cmd2(enc_cas1(1'b1, bg, ba, 1'b1, BGW, BAW),
               enc_cas2(1'b1, col, ap));

    qs     = lat_phase(0, RL_TGT, G);
    nslots = 16/2;
    ngrp   = (qs + nslots + G - 1) / G;

    repeat (t_rddata_en - (G > 1 ? 2 : 3)) @(posedge dfi_clk);
    for (int c = 0; c < ngrp; c++) begin
      en_v = '0;
      for (int p = 0; p < G; p++) begin
        si = c*G + p - qs;
        if (si >= 0 && si < nslots) en_v[p] = 1'b1;
      end
      @(posedge dfi_clk);
      dfi.rddata_en <= en_v;
    end
    @(posedge dfi_clk);
    dfi.rddata_en <= '0;
    // let the PHY's capture-and-present pipeline drain into the collector
    repeat (8) @(posedge dfi_clk);
  endtask

  // -------------------------------------------------------------------------
  // Test body
  // -------------------------------------------------------------------------
  logic [DQ_BITS-1:0] pat [16];
  int base_err;

  initial begin
    fails            = 0;
    dfi.address      = '0;
    dfi.cs           = '0;
    dfi.act_n        = '1;
    dfi.cke          = '1;
    dfi.odt          = '0;
    dfi.parity_in    = '0;
    dfi.reset_n      = 1'b0;
    dfi.dram_clk_disable = 1'b0;
    dfi.wrdata_en    = '0;
    dfi.wrdata       = '0;
    dfi.wrdata_mask  = '0;
    dfi.wrdata_cs    = '0;
    dfi.rddata_en    = '0;
    dfi.init_start   = 1'b0;
    dfi.ctrlupd_req  = 1'b0;
    dfi.phyupd_ack   = 1'b0;
    dfi.phymstr_ack  = 1'b0;

    repeat (10) @(posedge dfi_clk);
    dfi.reset_n    <= 1'b1;
    dfi.init_start <= 1'b1;

    wait (dfi.init_complete === 1'b1);
    $display("--- dfi_init_complete, gear ratio 1:%0d ---", G);
    idle_dfi(10);

    // ---- 0. DRAM initialisation (JESD79-5 3.3.1 step 7 ordering) ----
    $display("--- DRAM init: MR13 -> DLL RESET -> ZQCal Start/Latch ---");
    idle_tck(70);
    drive_cmd1(enc_mpc(8'b1000_0000));      // tDLLK / tCCD_L into MR13
    idle_tck(8);
    drive_cmd1(enc_mpc(MPC_DLL_RESET));
    idle_tck(8);
    drive_cmd1(enc_mpc(MPC_ZQCAL_START));
    idle_tck(2500);                         // tZQCAL is 1 us
    drive_cmd1(enc_mpc(MPC_ZQCAL_LATCH));
    idle_tck(80);                           // tZQLAT = max(30 ns, 8 nCK)

    // ---- 1. MRW MR0: BL16, RL=40. Then tell the PHY its new latencies. ----
    $display("--- MRW MR0: BL16, RL=%0d ---", RL_TGT);
    drive_cmd2(enc_mrw1(8'd0), enc_mrw2({1'b0, rl_to_mr0(RL_TGT), BL_BL16}));
    idle_tck(30);
    u_phy.set_latency(RL_TGT, WL_TGT);
    idle_dfi(2);
    $display("    PHY reports t_phy_wrlat=%0d t_rddata_en=%0d t_phy_rdlat=%0d",
             t_phy_wrlat, t_rddata_en, t_phy_rdlat);
    // The PHY runs write data through two extra register stages so DQS can
    // lead it by the write preamble, so wrlat is two cycles earlier than the
    // bare WL/G.
    if (t_phy_wrlat != WL_TGT/G - 2 || t_rddata_en != RL_TGT/G) begin
      $display("FAIL: exported latencies %0d/%0d, expected %0d/%0d",
               t_phy_wrlat, t_rddata_en, WL_TGT/G - 2, RL_TGT/G);
      fails++;
    end

    // ---- 2. ACT ----
    $display("--- ACT bg0 ba0 row 0x1234 ---");
    drive_cmd2(enc_act1(0, 0, 17'h1234, BGW, BAW), enc_act2(17'h1234, ROW_BITS));
    idle_tck(45);                       // > tRCD (39 nCK)

    // ---- 3. WR BL16 ----
    $display("--- WR col 0x040 over DFI ---");
    for (int i = 0; i < 16; i++) pat[i] = 16'hC300 + 16'(i);
    dfi_write_burst(0, 0, 11'h040, 1'b0, pat);
    idle_tck(60);                       // clear the burst and tWTR_L

    // ---- 4. RD BL16 and compare ----
    $display("--- RD col 0x040 over DFI ---");
    dfi_read_burst(0, 0, 11'h040, 1'b0);
    if (rd_q.size() != 16) begin
      $display("FAIL: collected %0d beats, expected 16", rd_q.size());
      fails++;
    end
    else begin
      for (int i = 0; i < 16; i++)
        if (rd_q[i] !== pat[i]) begin
          $display("MISMATCH beat %0d: expected %04h got %04h",
                   i, pat[i], rd_q[i]);
          fails++;
        end
      if (fails == 0)
        $display("PASS: BL16 round-tripped through the DFI bridge");
    end

    // ---- 5. PRE then REFab, to exercise the one-cycle command path ----
    idle_tck(40);
    base_err = u_dram.error_count();
    drive_cmd1(enc_pre_pb(0, 0, BGW, BAW));
    idle_tck(45);                       // > tRP
    drive_cmd1(enc_ref_ab());
    idle_tck(200);
    if (u_dram.error_count() != base_err) begin
      $display("FAIL: PRE/REF path produced %0d DRAM errors",
               u_dram.error_count() - base_err);
      fails++;
    end
    else $display("PASS: PREpb and REFab accepted with no violations");

    $display("=== tb_dfi_smoke: %0d failures, %0d DRAM errors total ===",
             fails, u_dram.error_count());
    if (fails == 0 && u_dram.error_count() == 0)
      $display("=== DFI SMOKE TEST PASSED ===");
    else
      $display("=== DFI SMOKE TEST FAILED ===");
    $finish;
  end

  initial begin
    #80_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
