// ---------------------------------------------------------------------------
// dfi_ddr5_phy.sv — DFI 5.2 <-> DDR5 pin bridge (PHY model)
//
// Sits between the RMC exchange fabric and ddr5_device. It owns the DRAM
// clock, so it also produces dfi_clk: a real PHY holds the PLL and hands the
// controller its clock, and modelling it that way keeps the gear ratio honest
// instead of hiding a divider in the testbench.
//
//   fabric --dfi_if.ctrl--> [ dfi_ddr5_phy ] --CK/CS_n/CA/DQ/DQS--> ddr5_device
//
// Timing model
// ------------
// Every path uses one and the same pipeline: the DFI group sampled at dfi
// clock cycle D appears on the DRAM pins at absolute tCK slots D*G+0 .. D*G+G-1,
// one phase per slot. That single rule fixes all three latencies, and the
// arithmetic the controller needs is in dfi_pkg::lat_cycles / lat_phase.
//
// DQ and DQS are deliberately not edge-aligned with each other:
//   writes  - DQ changes on the tCK boundary, DQS strobes a quarter cycle in,
//             so the DRAM captures mid-eye. This is DDR5's centre-aligned
//             write DQS, and it is also what keeps model and PHY off the same
//             simulation edge.
//   reads   - the DRAM drives DQ and DQS edge-aligned; the PHY samples a
//             quarter cycle after each edge, again mid-eye.
//
// Not modelled here (later stages): DQS gate training, per-bit deskew, ODT
// timing, DBI, CRC, CA parity generation, frequency change.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

module dfi_ddr5_phy
  import ddr5_pkg::*;
  import dfi_pkg::*;
#(
  parameter int  G        = 2,        // gear ratio, dfi_clk : tCK
  parameter int  DQ_BITS  = 16,
  parameter int  N_CS     = 1,
  parameter real TCK_PS   = 416.7,    // DDR5-4800B
  parameter int  INIT_CK  = 64,       // tCK from init_start to init_complete
  parameter int  RL_INIT  = 22,       // MR0 power-on default; see set_latency()
  parameter int  WL_INIT  = 20
)(
  output logic                    dfi_clk,
  dfi_if.phy                      dfi,

  // ---- exported PHY latencies, in dfi_clk cycles, for phase 0 ----
  output int                      t_phy_wrlat,
  output int                      t_phy_rdlat,
  output int                      t_rddata_en,

  // ---- DRAM pins ----
  output logic                    CK_t,
  output logic                    CK_c,
  output logic                    CS_n,
  output logic [CA_BITS-1:0]      CA,
  output logic                    RESET_n,
  inout  wire  [DQ_BITS-1:0]      DQ,
  inout  wire                     DQS_t,
  inout  wire                     DQS_c,
  output logic [(DQ_BITS/8)-1:0]  DM_n
);

  localparam int PH_DATA_W = 2 * DQ_BITS;
  localparam int PH_MASK_W = 2 * (DQ_BITS/8);

  // =========================================================================
  // Clocks. The PHY generates CK and divides it down to dfi_clk, so dfi_clk's
  // rising edge always coincides with the tCK slot whose phase index is 0.
  // =========================================================================
  logic ck_int;
  initial ck_int = 1'b0;
  always #(TCK_PS/2.0) ck_int = ~ck_int;

  assign CK_t = ck_int;
  assign CK_c = ~ck_int;

  int              ck_phase;
  longint unsigned tck_slot;

  initial begin
    ck_phase = 0;
    tck_slot = 0;
  end

  always @(posedge ck_int) begin
    tck_slot <= tck_slot + 1;
    ck_phase <= (ck_phase == G-1) ? 0 : ck_phase + 1;
  end

  always_comb begin
    if (G == 1) dfi_clk = ck_int;
    else        dfi_clk = (ck_phase < G/2);
  end

  // =========================================================================
  // Latency export. RL/WL are MR0 state, so a testbench or the init FSM calls
  // set_latency() after programming MR0; the controller reloads its t_phy_*
  // CSRs from these outputs, exactly as DFI intends.
  // =========================================================================
  int rl_cur, wl_cur;

  initial begin
    rl_cur = RL_INIT;
    wl_cur = WL_INIT;
  end

  task automatic set_latency(input int rl, input int wl);
    rl_cur = rl;
    wl_cur = wl;
  endtask

  // Phase-0 values; other phases go through dfi_pkg::lat_cycles/lat_phase.
  // Read data is presented one dfi cycle after capture, and the capture group
  // is itself one cycle after the enable was driven, hence the +2.
  // Two dfi cycles earlier than the bare WL, because the write data goes
  // through two extra register stages so DQS can lead it by the preamble.
  assign t_phy_wrlat = lat_cycles(0, wl_cur, G) - 2;
  assign t_rddata_en = lat_cycles(0, rl_cur, G);
  assign t_phy_rdlat = lat_cycles(0, rl_cur, G) + 2;

  // =========================================================================
  // DFI group registers. Sampling here is the one-dfi-cycle pipeline that the
  // whole timing model rests on.
  // =========================================================================
  logic [G*CA_BITS-1:0]   ca_q;
  logic [G*N_CS-1:0]      cs_q;
  logic [G-1:0]           wren_q,  wren_q2,  wren_q3;
  logic [G*PH_DATA_W-1:0] wrd_q,   wrd_q2,   wrd_q3;
  logic [G*PH_MASK_W-1:0] wrm_q,   wrm_q2,   wrm_q3;
  logic [G-1:0]           rden_q;

  always @(posedge dfi_clk) begin
    ca_q   <= dfi.address;
    cs_q   <= dfi.cs;
    wren_q <= dfi.wrdata_en;
    wrd_q  <= dfi.wrdata;
    wrm_q  <= dfi.wrdata_mask;
    // Two extra stages on the write data. DQS is enabled from the earlier
    // stages, so the strobe leads the data by two dfi cycles and the DRAM sees
    // a preamble of 2*G tCK -- enough for MR8's 2 tCK minimum at every gear
    // ratio. One stage is not enough: the unregistered enable is asserted in
    // the same timestep the DRAM samples on, so it contributes no measurable
    // lead, leaving only 1 tCK at 1:1.
    wren_q2 <= wren_q;   wrd_q2 <= wrd_q;   wrm_q2 <= wrm_q;
    wren_q3 <= wren_q2;  wrd_q3 <= wrd_q2;  wrm_q3 <= wrm_q2;
    rden_q <= dfi.rddata_en;
  end

  // =========================================================================
  // Command path. ck_phase and ca_q both settle at the tCK edge, so the pins
  // are stable well before the DRAM samples them at the next rising edge.
  //
  // DDR5 has no CKE and no ODT ball -- power-down is the PDE command and ODT
  // is mode-register controlled -- so dfi.cke and dfi.odt are accepted and
  // ignored here rather than routed to pins that do not exist.
  // =========================================================================
  // CA and CS are SDR: launched on the falling edge so they are stable across
  // the rising edge the DRAM samples on. Driving them combinationally off
  // ck_phase would change the pin on that very edge, and the DRAM would latch
  // the previous slot -- a one-slot skew against the DQ path, which has no
  // such race because DQS strobes mid-beat.
  logic [CA_BITS-1:0] ca_pin;
  logic               cs_n_pin;

  initial begin
    ca_pin   = '0;
    cs_n_pin = 1'b1;
  end

  always @(negedge ck_int) begin
    int nph;
    logic [G*CA_BITS-1:0] ca_src;
    logic [G*N_CS-1:0]    cs_src;
    nph = (ck_phase == G-1) ? 0 : ck_phase + 1;
    // Phase 0 belongs to the group that ca_q latches on the very edge this
    // pin will be sampled by, so for that phase take the value straight off
    // the interface -- the controller has already driven it.
    ca_src = (nph == 0) ? dfi.address : ca_q;
    cs_src = (nph == 0) ? dfi.cs      : cs_q;
    ca_pin   <= ca_src[nph*CA_BITS +: CA_BITS];
    cs_n_pin <= ~(|cs_src[nph*N_CS +: N_CS]);
  end

  assign CA      = ca_pin;
  assign CS_n    = cs_n_pin;
  assign RESET_n = dfi.reset_n;

  // =========================================================================
  // Write path
  // =========================================================================
  logic                  dq_oe;
  logic                  dqs_oe;
  logic                  dqs_drv;
  logic [DQ_BITS-1:0]    dq_drv;
  logic [(DQ_BITS/8)-1:0] dm_drv;

  initial dqs_drv = 1'b0;

  assign dq_oe = wren_q3[ck_phase];

  // DQS is enabled a full dfi cycle ahead of the data, off the unregistered
  // enable. That lead is the write preamble: the DRAM's capture window has not
  // opened yet, so those edges are ignored, and the pin is never driven from Z
  // on the same edge the DRAM is sampling.
  assign dqs_oe = (|dfi.wrdata_en) | (|wren_q) | (|wren_q2) | (|wren_q3);

  // Low half of a phase is the rising-edge beat, high half the falling one.
  always_comb begin
    if (ck_int) begin
      dq_drv = wrd_q3[ck_phase*PH_DATA_W +: DQ_BITS];
      dm_drv = ~wrm_q3[ck_phase*PH_MASK_W +: (DQ_BITS/8)];
    end
    else begin
      dq_drv = wrd_q3[ck_phase*PH_DATA_W + DQ_BITS +: DQ_BITS];
      dm_drv = ~wrm_q3[ck_phase*PH_MASK_W + (DQ_BITS/8) +: (DQ_BITS/8)];
    end
  end

  assign DQ    = dq_oe  ? dq_drv  : {DQ_BITS{1'bz}};
  assign DQS_t = dqs_oe ? dqs_drv : 1'bz;
  assign DQS_c = dqs_oe ? ~dqs_drv : 1'bz;
  assign DM_n  = dq_oe  ? dm_drv  : {(DQ_BITS/8){1'b1}};

  // Strobe a quarter cycle into each beat, so DQ is stable either side of it.
  always @(posedge ck_int or negedge ck_int) begin
    if (dqs_oe) begin
      #(TCK_PS/4.0);
      dqs_drv = ~dqs_drv;
    end
  end

  // =========================================================================
  // Read path. dfi_rddata_en declares the capture window; the PHY samples the
  // pins mid-beat and hands the group up one dfi cycle later, with
  // dfi_rddata_valid mirroring the enable through the same pipeline.
  // =========================================================================
  logic [G*PH_DATA_W-1:0] rd_cap;

  always @(posedge ck_int or negedge ck_int) begin
    int ph;
    bit rising;
    rising = ck_int;
    // Wait for mid-beat BEFORE reading ck_phase or rden_q. Both update through
    // nonblocking assignments on this same edge, so reading them here rather
    // than at the edge is what makes a rising-edge beat land in the phase it
    // actually belongs to.
    #(TCK_PS/4.0);
    ph = ck_phase;
    if (rden_q[ph]) begin
      if (rising) rd_cap[ph*PH_DATA_W +: DQ_BITS]           = DQ;
      else        rd_cap[ph*PH_DATA_W + DQ_BITS +: DQ_BITS] = DQ;
    end
  end

  always @(posedge dfi_clk) begin
    dfi.rddata       <= rd_cap;
    dfi.rddata_valid <= rden_q;
    dfi.rddata_cs    <= '0;   // TODO: per-rank return tagging when N_CS > 1
  end

  // =========================================================================
  // Status, update and error interfaces
  // =========================================================================
  int init_cnt;

  initial begin
    dfi.init_complete = 1'b0;
    dfi.ctrlupd_ack   = 1'b0;
    dfi.phyupd_req    = 1'b0;
    dfi.phyupd_type   = PHYUPD_TYPE0;
    dfi.phymstr_req   = 1'b0;
    dfi.error         = 1'b0;
    dfi.error_info    = ERR_NONE;
    init_cnt          = 0;
  end

  always @(posedge ck_int) begin
    if (!dfi.reset_n) begin
      init_cnt          <= 0;
      dfi.init_complete <= 1'b0;
    end
    else if (dfi.init_start && !dfi.init_complete) begin
      if (init_cnt >= INIT_CK) dfi.init_complete <= 1'b1;
      else                     init_cnt <= init_cnt + 1;
    end
  end

  // Controller update: this model has nothing to retrain, so it acknowledges
  // immediately. A PHY that needs the CA bus quiesced would hold ack off here.
  always @(posedge dfi_clk) dfi.ctrlupd_ack <= dfi.ctrlupd_req;

  // PHY-initiated update and PHY-master requests. A model has no real reason
  // to need the bus back, so rather than inventing a random generator these
  // are driven by the testbench calling request_phyupd() / request_phymstr();
  // the four-phase handshake against the controller is modelled properly.
  task automatic request_phyupd(input logic [1:0] utype);
    dfi.phyupd_type = utype;
    dfi.phyupd_req  = 1'b1;
    @(posedge dfi.phyupd_ack);
    @(posedge dfi_clk);
    dfi.phyupd_req  = 1'b0;
    @(negedge dfi.phyupd_ack);
  endtask

  task automatic request_phymstr();
    dfi.phymstr_req = 1'b1;
    @(posedge dfi.phymstr_ack);
    @(posedge dfi_clk);
    dfi.phymstr_req = 1'b0;
    @(negedge dfi.phymstr_ack);
  endtask

  // Not modelled: frequency change (dfi_freq_ratio / dfi_freq_fsp), DQS gate
  // training and per-bit deskew. The DRAM does emit a read preamble, so a PHY
  // that wants to model gating has an edge to gate on.

  // More than one rank selected in a phase is a fabric bug, not a DRAM one.
  always @(posedge dfi_clk) begin
    dfi.error      <= 1'b0;
    dfi.error_info <= ERR_NONE;
    if (N_CS > 1) begin
      for (int p = 0; p < G; p++)
        if ($countones(dfi.cs[p*N_CS +: N_CS]) > 1) begin
          dfi.error      <= 1'b1;
          dfi.error_info <= ERR_MULTI_CS;
        end
    end
  end

endmodule
