// ---------------------------------------------------------------------------
// ddr5_device.sv — behavioral DDR5 SDRAM device model (JESD79-5)
//
// Stage 1 scope: CA decode (Table 241), per-bank state machine, the full
// core timing-check matrix, mode registers, sparse storage, and the DQ/DQS
// read and write datapath. Refresh management, on-die ECC, power states and
// training arrive in later stages; the hooks they attach to are marked TODO.
//
// Timing philosophy: every check is an integer compare on a free-running CK
// counter. JEDEC's max(nCK, ns) floors are resolved once in ddr5_timing_pkg,
// so nothing here depends on simulator time resolution.
// ---------------------------------------------------------------------------
`timescale 1ps/1ps

module ddr5_device
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;
  import ddr5_ecc_pkg::*;
#(
  parameter int DQ_BITS   = 16,        // x4 / x8 / x16
  parameter int BG_BITS   = 2,         // 2 for x16, 3 for x4/x8
  parameter int BA_BITS   = 2,
  parameter int ROW_BITS  = 17,        // R0~R16 at 32 Gb
  parameter int COL_BITS  = 10,        // C0~C9 for x16, C0~C10 for x4
  parameter speed_bin_e SPEED_BIN = BIN_DDR5_4800B,
  parameter density_e   DENSITY   = DEN_32G,
  parameter bit         CHECK     = 1'b1,   // enable protocol/timing checks
  parameter bit         VERBOSE   = 1'b0,   // log every decoded command
  parameter string      DEV_NAME  = "DDR5",
  // Initialisation takes milliseconds of real time (tINIT3 alone is 4 ms).
  // INIT_FAST collapses the untimed waiting to something a simulation can
  // sit through, while still enforcing the ordering rules that matter.
  parameter bit         INIT_FAST = 1'b1,
  // Refresh-management personality. These are read-only, vendor-specific mode
  // register fields (JESD79-5 4.41), so they are parameters here and are
  // published through MR58 / MR59 for the controller to read with MRR.
  parameter bit         RFM_REQUIRED = 1'b1,
  parameter logic [3:0] RAAIMT_CODE  = 4'b1001,   // 72 normal / 36 FGR
  parameter logic [2:0] RAAMMT_CODE  = 3'b100,    // 4x RAAIMT
  parameter logic [1:0] RAADEC_CODE  = 2'b00,     // REF decrements by RAAIMT
  // ALERT_n pulse width, in tCK, used to flag a write-CRC error.
  parameter int         ALERT_PW_CK  = 8
)(
  input  wire                      CK_t,
  input  wire                      CK_c,
  input  wire                      CS_n,
  input  wire [CA_BITS-1:0]        CA,
  input  wire                      RESET_n,
  inout  wire [DQ_BITS-1:0]        DQ,
  inout  wire                      DQS_t,
  inout  wire                      DQS_c,
  input  wire [(DQ_BITS/8)-1:0]    DM_n,
  output wire                      ALERT_n
);

  localparam int N_BG     = 1 << BG_BITS;
  localparam int N_BA     = 1 << BA_BITS;
  localparam int N_BANKS  = N_BG * N_BA;
  localparam int N_COL    = 1 << COL_BITS;
  localparam int MAX_BL   = 16;

  // On-die ECC geometry (JESD79-5 4.35). A x8 part maps its whole burst to one
  // 128-bit code word; a x16 splits into two, DQ[7:0] and DQ[15:8], fetched
  // from two internal banks at the same external bank address and checked in
  // parallel. A x4 transfers only 64 bits per burst and the real part fetches
  // a second 64-bit section internally to complete the code word; the model
  // keeps the pair local to one block instead, which is invisible to a
  // controller because the check bits never leave the die.
  localparam int LANE_W  = (DQ_BITS >= 8) ? 8 : DQ_BITS;
  localparam int N_LANES = (DQ_BITS >= 8) ? (DQ_BITS/8) : 1;
  localparam int CW_BITS = MAX_BL * LANE_W;

  ddr5_timing_t T;
  initial T = get_timing(SPEED_BIN, DENSITY);

  // =========================================================================
  // Cycle counter — the time base for every check
  // =========================================================================
  longint unsigned ck_cnt;

  // Command-reference cycle. For a 2-cycle command JEDEC measures every
  // spacing from the FIRST CA cycle, but the model only has the full operand
  // set on the second, so execution reads cur_ck rather than ck_cnt.
  longint unsigned cur_ck;

  // =========================================================================
  // Storage — sparse, one entry per addressable column word
  // =========================================================================
  logic [DQ_BITS-1:0] mem [longint unsigned];

  function automatic longint unsigned mem_key(input int bank,
                                              input int row,
                                              input int col);
    return (longint'(bank) << (ROW_BITS + COL_BITS))
         | (longint'(row)  <<  COL_BITS)
         |  longint'(col);
  endfunction

  // =========================================================================
  // Mode registers
  // =========================================================================
  logic [OP_BITS-1:0] mr [N_MR];

  // Live views of the MR bits the core actually consumes
  int  cfg_RL, cfg_WL, cfg_BL;
  bit  cfg_2n_mode;
  bit  cfg_fgr_mode;          // MR4 OP[4]: 0 = tRFC1, 1 = tRFC2

  function automatic void refresh_mr_views();
    cfg_RL       = mr0_to_rl(mr[MR0][6:2]);
    cfg_WL       = cfg_RL - 2;                       // Table 26 NOTE 2
    case (mr[MR0][1:0])
      BL_BL16:     cfg_BL = 16;
      BL_BC8_OTF:  cfg_BL = 8;                       // OTF resolved per-command
      BL_BL32:     cfg_BL = 32;
      default:     cfg_BL = 16;
    endcase
    // MR2 OP[2] is 2N mode; OP[1] is write-levelling training. An earlier
    // revision of this model had them swapped.
    cfg_2n_mode  = mr[MR2][2];
    cfg_fgr_mode = mr[MR4][4];
    // RAAIMT and RAAMMT both halve/double with the refresh mode, so they have
    // to be re-derived whenever MR4 OP[4] moves.
    cfg_raaimt   = raaimt_of(mr[MR58][4:1], cfg_fgr_mode);
    cfg_raammt   = raammt_mult_of(mr[MR58][7:5], cfg_fgr_mode) * cfg_raaimt;
    cfg_raadec   = raadec_of(mr[MR59][7:6], cfg_raaimt);
  endfunction

  // =========================================================================
  // Bank state
  // =========================================================================
  bank_state_e     bank_st  [N_BANKS];
  int              open_row [N_BANKS];
  dev_state_e      dev_st;

  // Timestamps, all in CK counts. `NEVER` keeps first-command checks quiet.
  localparam longint unsigned NEVER = 64'h8000_0000_0000_0000;

  longint unsigned t_act    [N_BANKS];  // last ACT to this bank
  longint unsigned t_pre    [N_BANKS];  // last PRE of this bank
  longint unsigned t_rd     [N_BANKS];  // last RD  to this bank
  longint unsigned t_wr     [N_BANKS];  // last WR  to this bank
  longint unsigned t_ref_sb [N_BANKS];  // last REFsb/RFMsb on this bank

  longint unsigned t_act_bg [N_BG];     // last ACT in this bank group
  longint unsigned t_rd_bg  [N_BG];     // last RD  in this bank group
  longint unsigned t_wr_bg  [N_BG];     // last WR  in this bank group

  longint unsigned t_act_any, t_pre_any, t_rd_any, t_wr_any;
  longint unsigned t_wr_dend;           // end of the last write data burst
  longint unsigned t_rd_dend;           // end of the last read data burst
  longint unsigned t_ref_ab;            // last REFab / RFMab
  longint unsigned t_mrw, t_mrr;

  // tFAW: rolling window of the last 4 ACT times
  longint unsigned faw_q [4];
  int              faw_ptr;

  int  err_count;
  int  cmd_count;

  // ---- refresh management (JESD79-5 4.41) ----
  int              raa [N_BANKS];      // rolling accumulated ACT, per bank
  int              cfg_raaimt;
  int              cfg_raammt;
  int              cfg_raadec;
  bit              refi_flagged;       // tREFI already reported this interval

  // ---- initialisation ----
  longint unsigned t_reset_exit;       // ck_cnt when RESET_n went high
  longint unsigned t_cfg_ok;           // first cycle a config command is legal
  bit              init_mr13;          // MPC tDLLK/tCCD_L seen
  bit              init_dll_reset;     // MPC DLL RESET seen
  bit              init_zq_start;
  bit              init_zq_latch;

  // ---- ZQ calibration windows ----
  longint unsigned t_zq_start;         // ZQCal Start issued
  longint unsigned t_zq_latch;         // ZQCal Latch issued
  bit              zq_busy;            // inside tZQCAL
  bit              zq_latching;        // inside tZQLAT, CA must stay deselect

  // ---- power states ----
  longint unsigned t_pde, t_sre;

  // ---- on-die ECC ----
  ecc_col_t        H [ECC_DATA_BITS];
  logic [7:0]      ecc_store [longint unsigned];   // key = block, lane packed
  int              ecc_ce_count;                   // corrected single-bit
  int              ecc_due_count;                  // detected, uncorrected

  // ---- ECS (Error Check and Scrub) ----
  longint unsigned t_ecs;              // last manual ECS command
  int              ecs_bank, ecs_row, ecs_blk;
  int              ecs_raw_errors;     // before the threshold filter
  int              ecs_ec;             // MR20
  int              ecs_eprc;           // MR19, errors in the worst row
  int              ecs_eprc_row;
  int              ecs_eprc_bank;
  int              ecs_row_errors;     // errors seen in the row being scanned

  // ---- training ----
  logic            train_drv;        // training output overrides the read path
  logic            train_val;        // pseudo-static value driven on all DQ
  logic            catm_val;
  longint unsigned t_catm_cs;        // last CS_n assertion in CA training
  int              cs_low_run;       // consecutive CS_n low cycles
  logic [3:0]      cstm_samp;
  int              cstm_idx;
  logic            wl_val;
  dev_state_e      dev_st_saved;     // state to return to when training exits

  // ---- PDA ----
  logic [3:0]      pda_enum_id;
  logic [3:0]      pda_sel_id;
  bit              pda_enum_mode;

  // ---- Vref / RTT shadow registers ----
  logic [6:0]      shadow_vrefca, shadow_vrefcs;
  logic [7:0]      shadow_rtt_ck, shadow_rtt_cs, shadow_rtt_ca, shadow_rtt_park;

  // ---- write preamble measurement ----
  // Counting DQS edges ahead of the burst is robust; watching for the pin
  // going high-Z is not, because a multiply-driven tristate net can glitch
  // through Z during evaluation.
  // The preamble is DQS being driven ahead of the burst. It is measured by
  // sampling the pin on CK edges and counting how many cycles it has been
  // driven, because a compliant preamble mostly holds DQS low -- counting
  // transitions would measure the pattern, not the duration -- and because a
  // transition-sensitive check cannot see a pin leaving high-Z at all.
  int              dqs_run;          // consecutive CK edges with DQS driven
  int              pre_len;          // that count, frozen when the burst starts

  // ---- write CRC ----
  logic [DQ_BITS-1:0] wr_crc_rx [2];   // the two CRC UIs after the burst
  logic [DQ_BITS-1:0] wr_beats  [MAX_BL];
  logic               alert_n_r;
  longint unsigned    t_alert;
  longint unsigned t_pd_exit, t_sr_exit;

  // =========================================================================
  // Reporting
  // =========================================================================
  function automatic void viol(input string what, input string detail);
    if (!CHECK) return;
    err_count++;
    $display("%0t [%s] TIMING VIOLATION %s: %s (ck=%0d)",
             $time, DEV_NAME, what, detail, cur_ck);
  endfunction

  function automatic void prot(input string detail);
    if (!CHECK) return;
    err_count++;
    $display("%0t [%s] PROTOCOL ERROR: %s (ck=%0d)",
             $time, DEV_NAME, detail, cur_ck);
  endfunction

  // Check that `now - last >= req`, skipping the check if `last` is NEVER.
  function automatic void chk(input string name,
                              input longint unsigned last,
                              input int req,
                              input string ctx);
    if (!CHECK) return;
    if (last == NEVER) return;
    if ((cur_ck - last) < longint'(req))
      viol(name, $sformatf("%s: need %0d nCK, saw %0d", ctx, req,
                           int'(cur_ck - last)));
  endfunction

  // =========================================================================
  // Command capture — CA is SDR, sampled on the rising edge of CK_t
  // =========================================================================
  typedef struct {
    ddr5_cmd_e         cmd;
    int                bg, ba, bank;
    int                row, col;
    logic [3:0]        cstart;      // {C3,C2,C1,C0} for burst ordering
    bit                ap;          // auto precharge
    logic [MRA_BITS-1:0] mra;
    logic [OP_BITS-1:0]  op;
    int                bl;
  } decoded_t;

  // A cleared decode record. Cannot use '{default:0} because the enum field
  // would take an out-of-range implicit value.
  function automatic decoded_t d_clear();
    decoded_t z;
    z.cmd = CMD_DES; z.bg = 0; z.ba = 0; z.bank = 0;
    z.row = 0; z.col = 0; z.cstart = '0; z.ap = 1'b0;
    z.mra = '0; z.op = '0; z.bl = 16;
    return z;
  endfunction

  bit                    wait2;          // second cycle of a 2-cycle command
  ddr5_cmd_e             c1_cmd;
  logic [CA_BITS-1:0]    c1_ca;
  longint unsigned       c1_ck;

  // =========================================================================
  // Read / write burst scheduling
  // =========================================================================
  typedef struct {
    bit                 valid;
    longint unsigned    launch_ck;   // CK count at which beat 0 appears on DQ
    int                 nbeats;
    int                 bank, row;
    logic [3:0]         cstart;
    int                 col_base;
  } burst_t;

  burst_t rd_pend, wr_pend;

  bit                     rd_driving;
  bit                     rd_pre_active;    // read preamble, DQS before data
  longint unsigned        rd_pre_ck;
  int                     rd_beat;
  int                     rd_nbeats;
  logic [DQ_BITS-1:0]     rd_data [MAX_BL];
  logic [DQ_BITS-1:0]     dq_out;
  bit                     dqs_out;

  // Write capture is strobed by DQS, not CK: DDR5 write DQS is centre-aligned
  // to DQ, so sampling on DQS edges is both what the part does and the only
  // race-free way to hand data from a PHY model driving DQ on CK edges.
  bit                     wr_open;       // capture window, owned by the CK block
  longint unsigned        wr_close_ck;
  int                     wr_seq;        // bumped by the CK block per window
  int                     wr_beat;       // owned by the DQS block
  int                     wr_seq_q;      // the window the DQS block is serving

  // In a training mode the DQ pins carry a pseudo-static loopback value on
  // every pin, not burst data, so it takes priority over the read path.
  assign DQ    = wl_training_on() ? {DQ_BITS{wl_val}}
               : train_drv        ? {DQ_BITS{train_val}}
               : rd_driving       ? dq_out : {DQ_BITS{1'bz}};
  assign DQS_t = (rd_driving | rd_pre_active) ?  dqs_out : 1'bz;
  assign DQS_c = (rd_driving | rd_pre_active) ? ~dqs_out : 1'bz;
  // ALERT_n's only defined use in DDR5 is signalling a write-CRC error: it is
  // pulled low for a fixed period and released. There is no CA parity in
  // JESD79-5 for it to report.
  assign ALERT_n = alert_n_r;

  // =========================================================================
  // Reset / init
  // =========================================================================
  task automatic do_reset();
    int i;
    ck_cnt   = 0;
    dev_st   = DS_RESET;
    wait2    = 1'b0;
    err_count = 0;
    cmd_count = 0;
    rd_driving = 1'b0;  rd_pre_active = 1'b0;  rd_pre_ck = NEVER;
    wr_open = 1'b0;
    wr_close_ck = 0;  wr_beat = 0;  wr_seq = 0;  wr_seq_q = 0;
    rd_pend.valid = 1'b0; wr_pend.valid = 1'b0;
    faw_ptr = 0;
    for (i = 0; i < 4; i++) faw_q[i] = NEVER;
    for (i = 0; i < N_MR; i++) mr[i] = '0;
    // Power-on defaults: BL16, RL 22 (MR0 = 0), normal refresh.
    for (i = 0; i < N_BANKS; i++) begin
      bank_st[i]  = BS_IDLE;
      open_row[i] = -1;
      t_act[i] = NEVER; t_pre[i] = NEVER; t_rd[i] = NEVER;
      t_wr[i]  = NEVER; t_ref_sb[i] = NEVER;
    end
    for (i = 0; i < N_BG; i++) begin
      t_act_bg[i] = NEVER; t_rd_bg[i] = NEVER; t_wr_bg[i] = NEVER;
    end
    t_act_any = NEVER; t_pre_any = NEVER; t_rd_any = NEVER; t_wr_any = NEVER;
    t_wr_dend = NEVER; t_rd_dend = NEVER; t_ref_ab = NEVER;
    t_mrw = NEVER; t_mrr = NEVER;
    // MR58 / MR59 are read only and describe this part's refresh-management
    // personality. Publish them so an MRR returns what the parameters say.
    mr[MR58] = {RAAMMT_CODE, RAAIMT_CODE, RFM_REQUIRED};
    mr[MR59] = {RAADEC_CODE, 6'b0};
    refresh_mr_views();

    build_h(H);
    ecc_store.delete();
    ecc_ce_count   = 0;
    ecc_due_count  = 0;
    t_ecs          = NEVER;
    ecs_bank       = 0;
    ecs_row        = 0;
    ecs_blk        = 0;
    ecs_raw_errors = 0;
    ecs_ec         = 0;
    ecs_eprc       = 0;
    ecs_eprc_row   = 0;
    ecs_eprc_bank  = 0;
    ecs_row_errors = 0;
    alert_n_r      = 1'b1;
    t_alert        = NEVER;
    train_drv      = 1'b0;
    train_val      = 1'b0;
    catm_val       = 1'b0;
    t_catm_cs      = NEVER;
    cs_low_run     = 0;
    cstm_samp      = '0;
    cstm_idx       = 0;
    wl_val         = 1'b0;
    dev_st_saved   = DS_INIT;
    pda_enum_id    = 4'hF;
    pda_sel_id     = 4'hF;
    pda_enum_mode  = 1'b0;
    shadow_vrefca  = '0;
    shadow_vrefcs  = '0;
    shadow_rtt_ck  = '0;
    shadow_rtt_cs  = '0;
    shadow_rtt_ca  = '0;
    shadow_rtt_park= '0;
    dqs_run        = 0;
    pre_len        = 0;
    mr[MR8_ADDR]   = 8'b0000_1001;   // 2 tCK write preamble, 2 tCK read
    // Read training pattern power-on defaults (4.17.1)
    mr[MR26]       = 8'h5A;          // Read Pattern Data0 / LFSR0 seed
    mr[MR27]       = 8'h3C;          // Read Pattern Data1 / LFSR1 seed
    mr[MR28]       = 8'h00;          // pattern invert, lower byte
    mr[MR29]       = 8'h00;          // pattern invert, upper byte
    mr[MR30]       = 8'hFE;          // LFSR assignments
    for (i = 0; i < N_BANKS; i++) raa[i] = 0;
    refi_flagged   = 1'b0;
    t_reset_exit   = NEVER;
    t_cfg_ok       = NEVER;
    init_mr13      = 1'b0;
    init_dll_reset = 1'b0;
    init_zq_start  = 1'b0;
    init_zq_latch  = 1'b0;
    t_zq_start     = NEVER;
    t_zq_latch     = NEVER;
    zq_busy        = 1'b0;
    zq_latching    = 1'b0;
    t_pde          = NEVER;
    t_sre          = NEVER;
    t_pd_exit      = NEVER;
    t_sr_exit      = NEVER;
    dev_st         = DS_RESET;
  endtask

  initial begin do_reset(); cur_ck = 0; dqs_out = 1'b0; end

  always @(negedge RESET_n) do_reset();

  // =========================================================================
  // Bank helpers
  // =========================================================================
  function automatic int bank_of(input int bg, input int ba);
    return bg * N_BA + ba;
  endfunction

  task automatic open_bank(input int bank, input int row);
    bank_st[bank]  = BS_ACTIVE;
    open_row[bank] = row;
  endtask

  task automatic close_bank(input int bank);
    bank_st[bank]  = BS_IDLE;
    open_row[bank] = -1;
  endtask

  // =========================================================================
  // Timing checks per command class
  // =========================================================================
  task automatic check_act(input int bank, input int bg);
    int i, n_in_window;
    chk("tRC",   t_act[bank], T.tRC,   $sformatf("ACT->ACT bank %0d", bank));
    chk("tRP",   t_pre[bank], T.tRP,   $sformatf("PRE->ACT bank %0d", bank));
    chk("tRRD_L", t_act_bg[bg], T.tRRD_L, $sformatf("ACT->ACT BG %0d", bg));
    chk("tRRD_S", t_act_any,    T.tRRD_S, "ACT->ACT any BG");
    chk("tRFC1", t_ref_ab, cfg_fgr_mode ? T.tRFC2 : T.tRFC1, "REFab->ACT");
    chk("tRFCsb", t_ref_sb[bank], T.tRFCsb, $sformatf("REFsb->ACT bank %0d", bank));

    // tFAW: no more than 4 ACT inside a rolling tFAW window
    if (CHECK) begin
      n_in_window = 0;
      for (i = 0; i < 4; i++)
        if (faw_q[i] != NEVER && (cur_ck - faw_q[i]) < longint'(T.tFAW))
          n_in_window++;
      if (n_in_window >= 4)
        viol("tFAW", $sformatf("5th ACT inside %0d nCK window", T.tFAW));
    end

    if (bank_st[bank] != BS_IDLE)
      prot($sformatf("ACT to bank %0d which is not precharged (state %s)",
                     bank, bank_st[bank].name()));
  endtask

  task automatic check_cas(input int bank, input int bg, input bit is_wr);
    chk("tRCD", t_act[bank], T.tRCD, $sformatf("ACT->CAS bank %0d", bank));

    if (is_wr) begin
      chk("tCCD_L_WR", t_wr_bg[bg], T.tCCD_L_WR, $sformatf("WR->WR BG %0d", bg));
      chk("tCCD_S",    t_wr_any,    T.tCCD_S,    "WR->WR any BG");
      // Read-to-write turnaround is a bus-direction constraint, not per bank.
      chk("tRTW",      t_rd_any,    T.tRTW,      "RD->WR bus turnaround");
    end
    else begin
      chk("tCCD_L", t_rd_bg[bg], T.tCCD_L, $sformatf("RD->RD BG %0d", bg));
      chk("tCCD_S", t_rd_any,    T.tCCD_S, "RD->RD any BG");
      // Write-to-read is measured from the END of the write data burst.
      if (t_wr_dend != NEVER) begin
        if (t_wr_bg[bg] != NEVER && t_wr_bg[bg] >= t_wr_dend - longint'(cfg_WL + T.BL/2))
          chk("tWTR_L", t_wr_dend, T.tWTR_L, $sformatf("WR->RD BG %0d", bg));
        else
          chk("tWTR_S", t_wr_dend, T.tWTR_S, "WR->RD any BG");
      end
    end

    if (bank_st[bank] != BS_ACTIVE)
      prot($sformatf("%s to bank %0d with no open row (state %s)",
                     is_wr ? "WR" : "RD", bank, bank_st[bank].name()));
  endtask

  task automatic check_pre(input int bank);
    chk("tRAS", t_act[bank], T.tRAS, $sformatf("ACT->PRE bank %0d", bank));
    chk("tRTP", t_rd[bank],  T.tRTP, $sformatf("RD->PRE bank %0d", bank));
    chk("tPPD", t_pre_any,   T.tPPD, "PRE->PRE");
    // tWR runs from the end of the write data burst, not from the WR command.
    if (t_wr[bank] != NEVER && t_wr_dend != NEVER && t_wr_dend >= t_wr[bank])
      chk("tWR", t_wr_dend, T.tWR, $sformatf("write recovery bank %0d", bank));
  endtask

  task automatic check_ref_all();
    int i;
    chk(cfg_fgr_mode ? "tRFC2" : "tRFC1", t_ref_ab,
        cfg_fgr_mode ? T.tRFC2 : T.tRFC1, "REF/RFM -> REFab");
    for (i = 0; i < N_BANKS; i++)
      if (bank_st[i] != BS_IDLE)
        prot($sformatf("REFab with bank %0d not precharged", i));
  endtask

  // =========================================================================
  // On-die ECC (JESD79-5 4.35)
  //
  // Check bits are computed over a whole BL16 column block, one code word per
  // byte lane. On a read the DRAM corrects any single-bit error before handing
  // data back and, per the standard, does NOT write the correction into the
  // array -- only ECS scrubs. None of this is visible on the DQ pins, which is
  // the point: a controller sees clean data and finds out about the error rate
  // through the ECS transparency registers.
  // =========================================================================
  function automatic longint unsigned ecc_key(input int bank, input int row,
                                              input int blk, input int lane);
    return (longint'(bank) << (ROW_BITS + COL_BITS + 4))
         | (longint'(row)  << (COL_BITS + 4))
         | (longint'(blk)  << 4)
         |  longint'(lane);
  endfunction

  function automatic logic [ECC_DATA_BITS-1:0] ecc_gather(input int bank,
                                                          input int row,
                                                          input int blk,
                                                          input int lane);
    logic [ECC_DATA_BITS-1:0] w;
    logic [DQ_BITS-1:0]       v;
    longint unsigned          k;
    w = '0;
    for (int off = 0; off < MAX_BL; off++) begin
      k = mem_key(bank, row, blk*MAX_BL + off);
      v = mem.exists(k) ? mem[k] : '0;
      w[off*LANE_W +: LANE_W] = v[lane*LANE_W +: LANE_W];
    end
    return w;
  endfunction

  task automatic ecc_scatter(input int bank, input int row, input int blk,
                             input int lane,
                             input logic [ECC_DATA_BITS-1:0] w);
    longint unsigned k;
    logic [DQ_BITS-1:0] v;
    for (int off = 0; off < MAX_BL; off++) begin
      k = mem_key(bank, row, blk*MAX_BL + off);
      v = mem.exists(k) ? mem[k] : '0;
      v[lane*LANE_W +: LANE_W] = w[off*LANE_W +: LANE_W];
      mem[k] = v;
    end
  endtask

  // Recompute and store the check bits for a block. Called when a write burst
  // completes; a partial (BC8) burst is the read-modify-write case, and
  // gathering the whole block before recomputing is exactly that.
  task automatic ecc_update_block(input int bank, input int row, input int blk);
    for (int lane = 0; lane < N_LANES; lane++)
      ecc_store[ecc_key(bank, row, blk, lane)] =
          ecc_check_bits(ecc_gather(bank, row, blk, lane), H);
  endtask

  // Correct one lane into `w`. Returns the ecc_locate result so the caller can
  // tell no-error from corrected from DUE.
  function automatic int ecc_correct_lane(input int bank, input int row,
                                          input int blk, input int lane,
                                          output logic [ECC_DATA_BITS-1:0] w);
    longint unsigned k;
    int loc;
    k = ecc_key(bank, row, blk, lane);
    w = ecc_gather(bank, row, blk, lane);
    if (!ecc_store.exists(k)) return -1;      // never written: nothing to check
    loc = ecc_locate(ecc_syndrome(w, ecc_store[k], H), H);
    if (loc >= 0 && loc < ECC_DATA_BITS) w[loc] = ~w[loc];
    return loc;
  endfunction

  // Flip a bit in the array without touching the check bits, so the next read
  // of that block sees a genuine correctable error.
  task automatic inject_bit_error(input int bank, input int row, input int col,
                                  input int bit_idx);
    longint unsigned k;
    logic [DQ_BITS-1:0] v;
    k = mem_key(bank, row, col);
    v = mem.exists(k) ? mem[k] : '0;
    v[bit_idx] = ~v[bit_idx];
    mem[k] = v;
  endtask

  function automatic int ecc_corrected_count(); return ecc_ce_count;  endfunction
  function automatic int ecc_due_total();       return ecc_due_count; endfunction

  // =========================================================================
  // ECS -- Error Check and Scrub (JESD79-5 4.36)
  //
  // Unlike a read, ECS writes the correction back. It walks an internal
  // address counter, and the error counters feed the transparency registers:
  // EC (MR20) counts rows or code words with errors depending on MR14 OP[5],
  // EpRC (MR16-19) tracks the worst row and its address. Both are filtered by
  // the threshold in MR15 OP[2:0], so small error counts stay invisible.
  // =========================================================================
  function automatic int ecs_threshold();
    return ecs_threshold_of(mr[MR15][2:0]);
  endfunction

  task automatic ecs_publish();
    mr[MR16] = 8'(ecs_eprc_row[7:0]);
    mr[MR17] = 8'(ecs_eprc_row[15:8]);
    mr[MR18] = {1'b0,
                3'(ecs_eprc_bank / N_BA),          // BG2:BG0
                2'(ecs_eprc_bank % N_BA),          // BA1:BA0
                2'(ecs_eprc_row >> 16)};           // R17:R16
    mr[MR19] = {2'b0, 6'(ecs_eprc > 63 ? 63 : ecs_eprc)};
    mr[MR20] = 8'(ecs_ec > 255 ? 255 : ecs_ec);
  endtask

  task automatic ecs_reset_counters();
    ecs_raw_errors = 0;
    ecs_ec         = 0;
    ecs_eprc       = 0;
    ecs_eprc_row   = 0;
    ecs_eprc_bank  = 0;
    ecs_row_errors = 0;
    ecs_publish();
  endtask

  // Scan and scrub one code-word block, then advance the internal counter.
  task automatic ecs_step();
    logic [ECC_DATA_BITS-1:0] w;
    int loc, found;
    found = 0;
    for (int lane = 0; lane < N_LANES; lane++) begin
      loc = ecc_correct_lane(ecs_bank, ecs_row, ecs_blk, lane, w);
      if (loc >= 0) begin
        found++;
        if (loc < ECC_DATA_BITS) ecc_scatter(ecs_bank, ecs_row, ecs_blk, lane, w);
        // A check-bit error scrubs by simply rewriting the check bits.
        ecc_store[ecc_key(ecs_bank, ecs_row, ecs_blk, lane)] =
            ecc_check_bits(w, H);
      end
      else if (loc == -2) ecc_due_count++;
    end

    if (found > 0) begin
      ecs_raw_errors  = ecs_raw_errors + found;
      ecs_row_errors  = ecs_row_errors + found;
      // The threshold filter masks counts below the programmed value.
      if (ecs_raw_errors > ecs_threshold()) begin
        // MR14 OP[5]: 0 counts rows with errors, 1 counts code words.
        if (mr[MR14][5]) ecs_ec = ecs_ec + found;
        else if (ecs_row_errors == found) ecs_ec = ecs_ec + 1;
      end
      if (ecs_row_errors > ecs_eprc && ecs_row_errors >= ECS_RETC) begin
        ecs_eprc      = ecs_row_errors;
        ecs_eprc_row  = ecs_row;
        ecs_eprc_bank = ecs_bank;
      end
      ecs_publish();
    end

    // Advance: column block, then row, then bank. The counters reset when the
    // bank group counter wraps (4.36.3).
    ecs_blk = ecs_blk + 1;
    if (ecs_blk >= (N_COL/MAX_BL)) begin
      ecs_blk        = 0;
      ecs_row        = ecs_row + 1;
      ecs_row_errors = 0;
      if (ecs_row >= (1 << ROW_BITS)) begin
        ecs_row  = 0;
        ecs_bank = ecs_bank + 1;
        if (ecs_bank >= N_BANKS) begin
          ecs_bank = 0;
          ecs_reset_counters();
        end
      end
    end
  endtask

  // =========================================================================
  // Write CRC (JESD79-5 4.37)
  //
  // Enabled per nibble by MR50 OP[2:1]. The burst grows by two UI which carry
  // one CRC-8 per nibble over that nibble's 64 data bits. A mismatch sets the
  // MR50 error status bit and pulls ALERT_n low.
  //
  // The standard fixes the polynomial and that D[63] is sent first, but the
  // model has to pick an order for the four bits a nibble presents in the same
  // UI. It uses DQ-ascending within each UI, for both the data and the two CRC
  // UIs; a controller checked against this model must use the same convention.
  // =========================================================================
  function automatic bit wr_crc_enabled();
    return mr[MR50][1] | mr[MR50][2];
  endfunction

  function automatic logic [63:0] crc_data_of_nibble(input int nib);
    logic [63:0] d;
    d = '0;
    for (int beat = 0; beat < MAX_BL; beat++)
      for (int k = 0; k < 4; k++)
        d[63 - (beat*4 + k)] = wr_beats[beat][nib*4 + k];
    return d;
  endfunction

  function automatic logic [7:0] crc_rx_of_nibble(input int nib);
    logic [7:0] c;
    c = '0;
    for (int u = 0; u < 2; u++)
      for (int k = 0; k < 4; k++)
        c[7 - (u*4 + k)] = wr_crc_rx[u][nib*4 + k];
    return c;
  endfunction

  task automatic check_write_crc();
    logic [7:0] want, got;
    bit         bad;
    bad = 1'b0;
    for (int nib = 0; nib < DQ_BITS/4; nib++) begin
      // MR50 OP[1] covers the lower nibble of a byte lane, OP[2] the upper.
      if (!mr[MR50][1 + (nib % 2)]) continue;
      want = crc8_d64(crc_data_of_nibble(nib));
      got  = crc_rx_of_nibble(nib);
      if (want !== got) begin
        bad = 1'b1;
        if (CHECK)
          $display("%0t [%s] WRITE CRC ERROR nibble %0d: expected %02h got %02h",
                   $time, DEV_NAME, nib, want, got);
      end
    end
    if (bad) begin
      mr[MR50][3] = 1'b1;          // write CRC error status
      alert_n_r   = 1'b0;
      t_alert     = ck_cnt;
      err_count++;
    end
  endtask

  // =========================================================================
  // Training modes (JESD79-5 4.18 - 4.21)
  //
  // All three loopback modes drive a pseudo-static value on every DQ pin
  // rather than burst data, which is why they take priority over the read
  // path. What each one loops back:
  //
  //   CA training (CATM, 4.19)  XOR of the whole CA bus, sampled when CS_n is
  //                             asserted. CS_n assertions must be 4 tCK or
  //                             more apart, and asserting CS_n for 2 to 8
  //                             consecutive cycles exits the mode.
  //   CS training (CSTM, 4.20)  CS_n sampled on every CK rising edge, taken
  //                             four at a time, evaluated in pairs and ORed.
  //   Write levelling (4.21)    CK_t sampled on the rising edge of DQS, which
  //                             is how the host finds the CK-to-DQS offset.
  // =========================================================================
  function automatic bit wl_training_on();
    return mr[MR2][1];               // MR2 OP[1]
  endfunction

  function automatic bit in_training();
    return (dev_st == DS_CA_TRAINING) || (dev_st == DS_CS_TRAINING)
           || wl_training_on();
  endfunction

  // Table 315/316: an intermediate output is 0 only for the sample pair (0,1).
  function automatic logic cstm_pair(input logic a, input logic b);
    return !((a == 1'b0) && (b == 1'b1));
  endfunction

  task automatic training_ck_edge();
    // ---- CA training ----
    if (dev_st == DS_CA_TRAINING) begin
      if (!CS_n) begin
        cs_low_run = cs_low_run + 1;
        if (cs_low_run == 1) begin
          // A fresh assertion: check the 4 tCK spacing and take the sample.
          chk("tCATM_CS", t_catm_cs, 4, "CS_n assertions in CA training");
          t_catm_cs = ck_cnt;
          catm_val  = ^CA;           // Table 313: XOR of the CA bus
          train_val = catm_val;
          train_drv = 1'b1;
        end
        // Two to eight consecutive CS_n low cycles is the exit (4.19.3).
        if (cs_low_run == 2) begin
          dev_st    = dev_st_saved;
          train_drv = 1'b0;
          if (VERBOSE) $display("%0t [%s] CA training exit", $time, DEV_NAME);
        end
      end
      else cs_low_run = 0;
    end

    // ---- CS training ----
    else if (dev_st == DS_CS_TRAINING) begin
      cstm_samp[cstm_idx] = CS_n;
      cstm_idx = cstm_idx + 1;
      if (cstm_idx == 4) begin
        cstm_idx  = 0;
        train_val = cstm_pair(cstm_samp[0], cstm_samp[1])
                  | cstm_pair(cstm_samp[2], cstm_samp[3]);   // Table 317
        train_drv = 1'b1;
      end
    end

    else if (!wl_training_on() && train_drv && dev_st == DS_NORMAL)
      train_drv = 1'b0;
  endtask

  // =========================================================================
  // Read training pattern (4.17). An MRR to MR31 returns a BL16 pattern
  // instead of register contents.
  //
  //   MR25 OP[0] = 0  serial: the 16 UI are MR26 then MR27, MSB first
  //   MR25 OP[0] = 1  LFSR:   two Galois LFSRs seeded from MR26/MR27, with
  //                           MR30 choosing which one drives each DQ, and
  //                           OP[2:1] substituting a clock pattern for either
  //   MR28/MR29 invert per DQ, lower and upper byte.
  //
  // The standard defines the pattern in figures rather than equations; the
  // serialisation here is MSB-first per UI, which a controller checked against
  // this model must match.
  // =========================================================================
  task automatic gen_read_training_pattern();
    logic [7:0] l0, l1;
    logic       bit0, bit1, v;
    logic [DQ_BITS-1:0] inv;
    l0  = mr[MR26];
    l1  = mr[MR27];
    inv = DQ_BITS'({mr[MR29], mr[MR28]});

    for (int beat = 0; beat < MAX_BL; beat++) begin
      if (!mr[MR25][0]) begin
        // Serial: MR26 supplies UI 0..7, MR27 supplies UI 8..15.
        bit0 = (beat < 8) ? mr[MR26][7-beat] : mr[MR27][7-(beat-8)];
        bit1 = bit0;
      end
      else begin
        // LFSR, or a toggling clock pattern if MR25 OP[1]/OP[2] select it.
        bit0 = mr[MR25][1] ? beat[0] : l0[7];
        bit1 = mr[MR25][2] ? beat[0] : l1[7];
        l0   = lfsr8_next(l0);
        l1   = lfsr8_next(l1);
      end
      for (int d = 0; d < DQ_BITS; d++) begin
        // MR30 assigns a DQ to LFSR0 or LFSR1; in serial mode both are equal.
        v = mr[MR30][d % 8] ? bit1 : bit0;
        rd_data[beat][d] = v ^ inv[d];
      end
    end
  endtask

  // =========================================================================
  // Per DRAM Addressability (4.16). While a PDA select is in force, only the
  // device holding that enumerate ID accepts an MRW; ID 15 addresses all of
  // them, which is the reset state.
  // =========================================================================
  function automatic bit pda_selected();
    return (pda_sel_id == 4'hF) || (pda_sel_id == pda_enum_id);
  endfunction

  // =========================================================================
  // Initialisation (JESD79-5 3.3.1)
  //
  // The model does not police the analogue part of the ramp; it enforces what
  // a controller can actually get wrong: how long it must wait before the
  // first configuration command, which commands are legal while configuring,
  // and the mandatory MPC ordering
  //     MR13 (tDLLK/tCCD_L) -> DLL RESET -> ZQCal Start -> ZQCal Latch
  // before any training mode is entered.
  // =========================================================================
  function automatic int init_wait_ck();
    // tINIT3 + tINIT4 + tINIT5 + tXPR. INIT_FAST keeps the ordering rules but
    // shortens the untimed waiting so a testbench can reach normal operation.
    if (INIT_FAST) return 64;
    return T.tINIT3 + T.tINIT4 + T.tINIT5 + T.tXPR;
  endfunction

  function automatic bit is_config_cmd(input ddr5_cmd_e c);
    case (c)
      CMD_MRW, CMD_MRR, CMD_MPC, CMD_VREFCA, CMD_VREFCS,
      CMD_NOP, CMD_DES: return 1'b1;
      default:          return 1'b0;
    endcase
  endfunction

  // Gate every command on the device state it arrives in. Returns 0 if the
  // command must not be executed.
  function automatic bit check_cmd_legal(input ddr5_cmd_e c);
    // The CA bus must hold deselect for the whole of tZQLAT so the DRAM can
    // update its CA ODT calibration (4.23.1). Anything arriving with CS_n low
    // inside that window breaks it, NOP included.
    if (zq_latching) begin
      prot($sformatf("%s issued during tZQLAT: CA must stay deselect",
                     cmd_name(c)));
      return 1'b0;
    end

    case (dev_st)
      DS_RESET: begin
        prot($sformatf("%s issued before RESET_n de-asserted", cmd_name(c)));
        return 1'b0;
      end

      DS_INIT: begin
        if (!is_config_cmd(c)) begin
          prot($sformatf("%s is not legal during init: only MRR/MRW/MPC/VrefCA are allowed before training completes", cmd_name(c)));
          return 1'b0;
        end
        if (t_cfg_ok != NEVER && ck_cnt < t_cfg_ok) begin
          prot($sformatf("%s issued %0d nCK after reset exit, init/tXPR window needs %0d", cmd_name(c), int'(ck_cnt - t_reset_exit), init_wait_ck()));
          return 1'b0;
        end
        return 1'b1;
      end

      DS_POWER_DOWN: begin
        if (c != CMD_PDX) begin
          prot($sformatf("%s issued in power-down; only PDX exits",
                         cmd_name(c)));
          return 1'b0;
        end
        return 1'b1;
      end

      DS_SELF_REFRESH: begin
        // Self-refresh exit is any CS_n assertion; everything else in that
        // state would be a command the DRAM cannot see.
        return 1'b1;
      end

      default: return 1'b1;
    endcase
  endfunction

  // =========================================================================
  // Refresh management -- RAA counters (JESD79-5 4.41)
  //
  // Each ACT adds one to the target bank's rolling accumulated ACT count. REF
  // takes RAADEC off it, RFM takes RAAIMT off it, both flooring at zero. Once
  // a bank reaches RAAMMT no further ACT to it is allowed until a REF or RFM
  // brings it back down -- that last rule is the one a scheduler breaks.
  // =========================================================================
  task automatic raa_decrement(input int bank, input int amount);
    raa[bank] = (raa[bank] > amount) ? (raa[bank] - amount) : 0;
  endtask

  task automatic raa_decrement_all(input int amount);
    for (int i = 0; i < N_BANKS; i++) raa_decrement(i, amount);
  endtask

  task automatic raa_decrement_sb(input int ba, input int amount);
    for (int i = 0; i < N_BG; i++) raa_decrement(bank_of(i, ba), amount);
  endtask

  function automatic bit cfg_rfm_required();
    return mr[MR58][0];
  endfunction

  function automatic bit raa_blocks_act(input int bank);
    if (!cfg_rfm_required()) return 1'b0;
    if (cfg_raammt <= 0)     return 1'b0;
    return (raa[bank] >= cfg_raammt);
  endfunction

  // =========================================================================
  // tREFI. The interval between two REFab may be stretched to 5 x tREFI1 in
  // normal mode, 9 x tREFI2 in FGR (4.13.3). Beyond that, retention is not
  // guaranteed, so the model reports once per missed interval rather than
  // every cycle.
  // =========================================================================
  function automatic int refi_limit();
    return (cfg_fgr_mode ? 9 : 5) * (cfg_fgr_mode ? T.tREFI/2 : T.tREFI);
  endfunction

  task automatic check_refi();
    if (!CHECK) return;
    if (dev_st != DS_NORMAL) return;      // the clock may legitimately be idle
    if (t_ref_ab == NEVER)   return;
    if (refi_flagged)        return;
    if ((ck_cnt - t_ref_ab) > longint'(refi_limit())) begin
      refi_flagged = 1'b1;
      err_count++;
      $display("%0t [%s] TIMING VIOLATION tREFI: %0d nCK since last REFab, limit %0d (%0d x tREFI)", $time, DEV_NAME, int'(ck_cnt - t_ref_ab), refi_limit(), cfg_fgr_mode ? 9 : 5);
    end
  endtask

  // A command that follows a power-down or self-refresh exit has to clear
  // tXP / tXS first. chk() skips whichever exit has not happened.
  task automatic check_exit_windows(input ddr5_cmd_e c);
    if (c == CMD_PDX || c == CMD_NOP || c == CMD_DES) return;
    chk("tXP", t_pd_exit, T.tXP, "power-down exit -> command");
    chk("tXS", t_sr_exit, T.tXS, "self-refresh exit -> command");
  endtask

  // =========================================================================
  // Command execution
  // =========================================================================
  task automatic do_act(input decoded_t d);
    check_act(d.bank, d.bg);
    if (d.row >= (1 << ROW_BITS))
      prot($sformatf("ACT row %0d exceeds R0~R%0d", d.row, ROW_BITS-1));
    if (raa_blocks_act(d.bank))
      prot($sformatf("ACT to bank %0d with RAA=%0d at RAAMMT=%0d: a REF or RFM must run first", d.bank, raa[d.bank], cfg_raammt));
    raa[d.bank] = raa[d.bank] + 1;
    open_bank(d.bank, d.row);
    t_act[d.bank]  = cur_ck;
    t_act_bg[d.bg] = cur_ck;
    t_act_any      = cur_ck;
    faw_q[faw_ptr] = cur_ck;
    faw_ptr        = (faw_ptr + 1) % 4;
  endtask

  task automatic do_read(input decoded_t d);
    int beat, off, col, row, blk, loc;
    longint unsigned k;
    bit  has_ecc;
    logic [ECC_DATA_BITS-1:0] lane_w [N_LANES];
    check_cas(d.bank, d.bg, 1'b0);
    row = open_row[d.bank];
    if (d.col >= N_COL)
      prot($sformatf("RD column %0d exceeds C0~C%0d", d.col, COL_BITS-1));

    // On-die ECC runs on the whole code-word block before any of it reaches
    // the pins. A block that was never written has no check bits, so it is
    // served raw and unwritten columns stay X rather than being "corrected"
    // into zeros.
    blk     = d.col >> 4;
    has_ecc = ecc_store.exists(ecc_key(d.bank, row, blk, 0));
    if (has_ecc) begin
      for (int lane = 0; lane < N_LANES; lane++) begin
        loc = ecc_correct_lane(d.bank, row, blk, lane, lane_w[lane]);
        if (loc >= 0 && loc < ECC_DATA_BITS) ecc_ce_count++;
        else if (loc == -2)                  ecc_due_count++;
      end
    end

    // Pre-fetch the burst now; the DQ pins present it RL cycles later. The
    // correction is not written back to the array -- only ECS scrubs (4.35).
    for (beat = 0; beat < d.bl; beat++) begin
      off = burst_offset_rd(beat, d.cstart, d.bl);
      if (has_ecc) begin
        for (int lane = 0; lane < N_LANES; lane++)
          rd_data[beat][lane*LANE_W +: LANE_W] = lane_w[lane][off*LANE_W +: LANE_W];
      end
      else begin
        col = {d.col[COL_BITS-1:4], off[3:0]};
        k   = mem_key(d.bank, row, col);
        rd_data[beat] = mem.exists(k) ? mem[k] : {DQ_BITS{1'bx}};
      end
    end
    rd_pend.valid     = 1'b1;
    rd_pend.launch_ck = cur_ck + longint'(cfg_RL);
    rd_pre_ck         = rd_pend.launch_ck
                        - longint'(rd_preamble_ck_of(mr[MR8_ADDR][2:0]));
    rd_pend.nbeats    = d.bl;
    t_rd[d.bank]  = cur_ck;
    t_rd_bg[d.bg] = cur_ck;
    t_rd_any      = cur_ck;
    t_rd_dend     = cur_ck + longint'(cfg_RL) + longint'(d.bl/2);
    if (d.ap) begin
      // RDA: internal precharge starts tRTP after the read.
      bank_st[d.bank] = BS_PRECHARGING;
      t_pre[d.bank]   = cur_ck + longint'(T.tRTP);
      t_pre_any       = t_pre[d.bank];
    end
  endtask

  task automatic do_write(input decoded_t d);
    check_cas(d.bank, d.bg, 1'b1);
    if (d.col >= N_COL)
      prot($sformatf("WR column %0d exceeds C0~C%0d", d.col, COL_BITS-1));
    wr_pend.valid     = 1'b1;
    wr_pend.launch_ck = cur_ck + longint'(cfg_WL);
    wr_pend.nbeats    = d.bl;
    wr_pend.bank      = d.bank;
    wr_pend.row       = open_row[d.bank];
    wr_pend.cstart    = d.cstart;
    wr_pend.col_base  = d.col;
    t_wr[d.bank]  = cur_ck;
    t_wr_bg[d.bg] = cur_ck;
    t_wr_any      = cur_ck;
    t_wr_dend     = cur_ck + longint'(cfg_WL) + longint'(d.bl/2);
    if (d.ap) begin
      bank_st[d.bank] = BS_PRECHARGING;
      t_pre[d.bank]   = t_wr_dend + longint'(T.tWR);
      t_pre_any       = t_pre[d.bank];
    end
  endtask

  task automatic do_precharge(input decoded_t d, input ddr5_cmd_e which);
    int i, b;
    case (which)
      CMD_PREpb: begin
        check_pre(d.bank);
        close_bank(d.bank);
        t_pre[d.bank] = cur_ck;
      end
      CMD_PREab: begin
        for (i = 0; i < N_BANKS; i++) if (bank_st[i] != BS_IDLE) begin
          check_pre(i);
          close_bank(i);
          t_pre[i] = cur_ck;
        end
      end
      CMD_PREsb: begin
        // Same bank address in every bank group.
        for (i = 0; i < N_BG; i++) begin
          b = bank_of(i, d.ba);
          if (bank_st[b] != BS_IDLE) begin
            check_pre(b);
            close_bank(b);
            t_pre[b] = cur_ck;
          end
        end
      end
      default: ;
    endcase
    t_pre_any = cur_ck;
  endtask

  task automatic do_refresh(input decoded_t d, input ddr5_cmd_e which);
    int i, b, trfc;
    trfc = cfg_fgr_mode ? T.tRFC2 : T.tRFC1;
    case (which)
      CMD_REFab: begin
        check_ref_all();
        raa_decrement_all(cfg_raadec);
        t_ref_ab     = cur_ck;
        refi_flagged = 1'b0;
      end

      CMD_RFMab: begin
        // A part that does not require refresh management ignores RFM (4.41).
        if (!cfg_rfm_required()) return;
        chk("tRFM1", t_ref_ab, cfg_fgr_mode ? T.tRFM2 : T.tRFM1,
            "REF/RFM -> RFMab");
        for (i = 0; i < N_BANKS; i++)
          if (bank_st[i] != BS_IDLE)
            prot($sformatf("RFMab with bank %0d not precharged", i));
        raa_decrement_all(cfg_raaimt);
        t_ref_ab = cur_ck;
      end

      CMD_REFsb: begin
        for (i = 0; i < N_BG; i++) begin
          b = bank_of(i, d.ba);
          if (bank_st[b] != BS_IDLE)
            prot($sformatf("REFsb with bank %0d not precharged", b));
          chk("tRFCsb", t_ref_sb[b], T.tRFCsb,
              $sformatf("REFsb -> REFsb bank %0d", b));
          t_ref_sb[b] = cur_ck;
        end
        raa_decrement_sb(d.ba, cfg_raadec);
      end

      CMD_RFMsb: begin
        if (!cfg_rfm_required()) return;
        for (i = 0; i < N_BG; i++) begin
          b = bank_of(i, d.ba);
          if (bank_st[b] != BS_IDLE)
            prot($sformatf("RFMsb with bank %0d not precharged", b));
          chk("tRFMsb", t_ref_sb[b], T.tRFMsb,
              $sformatf("REF/RFM -> RFMsb bank %0d", b));
          t_ref_sb[b] = cur_ck;
        end
        raa_decrement_sb(d.ba, cfg_raaimt);
      end

      default: ;
    endcase
  endtask

  task automatic do_mrw(input decoded_t d);
    chk("tMRW", t_mrw, T.tMRW, "MRW->MRW");
    chk("tMRD", t_mrr, T.tMRD, "MRR->MRW");
    // 4.16: with a PDA select in force, only the device holding that
    // enumerate ID takes the write. ID 15 addresses everything.
    if (!pda_selected()) return;
    mr[int'(d.mra)] = d.op;
    // MR14 OP[6] is write-only: it resets the ECS counters and does not stick.
    if (int'(d.mra) == MR14 && d.op[6]) begin
      ecs_reset_counters();
      mr[MR14][6] = 1'b0;
    end
    refresh_mr_views();
    t_mrw = cur_ck;
    if (VERBOSE) $display("%0t [%s] MRW MR%0d <= 0x%02h", $time, DEV_NAME,
                          int'(d.mra), d.op);
  endtask

  task automatic do_mrr(input decoded_t d);
    int i;
    chk("tMRR", t_mrr, T.tMRR, "MRR->MRR");
    if (int'(d.mra) == MR31) begin
      // 4.17: an MRR to this address returns a BL16 training pattern, not
      // register contents. Read CRC has to be off for it.
      if (mr[MR50][0])
        prot("MRR to MR31 read training pattern with read CRC enabled");
      gen_read_training_pattern();
      rd_pend.valid     = 1'b1;
      rd_pend.launch_ck = cur_ck + longint'(cfg_RL);
      rd_pre_ck         = rd_pend.launch_ck
                          - longint'(rd_preamble_ck_of(mr[MR8_ADDR][2:0]));
      rd_pend.nbeats    = MAX_BL;
      t_mrr             = cur_ck;
      t_rd_any          = cur_ck;
      t_rd_dend         = cur_ck + longint'(cfg_RL) + 8;
      return;
    end
    // MRR returns the register value on DQ, RL cycles later, replicated over
    // the burst (JESD79-5 4.5). Model it as a normal read burst.
    for (i = 0; i < MAX_BL; i++)
      rd_data[i] = {{(DQ_BITS-OP_BITS){1'b0}}, mr[int'(d.mra)]};
    rd_pend.valid     = 1'b1;
    rd_pend.launch_ck = cur_ck + longint'(cfg_RL);
    rd_pre_ck         = rd_pend.launch_ck
                        - longint'(rd_preamble_ck_of(mr[MR8_ADDR][2:0]));
    rd_pend.nbeats    = 16;
    t_mrr     = cur_ck;
    t_rd_any  = cur_ck;
    t_rd_dend = cur_ck + longint'(cfg_RL) + 8;
  endtask

  task automatic do_mpc(input decoded_t d);
    mpc_field_e f;
    f = mpc_class(d.op);

    if (f == MPCF_TDLLK_TCCDL) begin
      // MPC "Configure tDLLK/tCCD_L" writes MR13's shadow; it takes effect on
      // the next DLL RESET or SRE with CA9 low (Table 290 NOTE 11).
      mr[MR13]  = {4'b0, d.op[3:0]};
      init_mr13 = 1'b1;
      return;
    end

    if (f == MPCF_RESERVED) begin
      prot($sformatf("MPC reserved opcode 0x%02h", d.op));
      return;
    end

    // Ranged opcodes carry a field in the low bits. Everything they touch is
    // a shadow register until MPC Apply commits it.
    case (f)
      MPCF_RTT_CK_A, MPCF_RTT_CK_B:     begin shadow_rtt_ck   = {5'b0, d.op[2:0]}; return; end
      MPCF_RTT_CS_A, MPCF_RTT_CS_B:     begin shadow_rtt_cs   = {5'b0, d.op[2:0]}; return; end
      MPCF_RTT_CA_A, MPCF_RTT_CA_B:     begin shadow_rtt_ca   = {5'b0, d.op[2:0]}; return; end
      MPCF_DQS_RTT_PARK, MPCF_RTT_PARK: begin shadow_rtt_park = {5'b0, d.op[2:0]}; return; end
      MPCF_PDA_ENUM_ID: begin
        // The enumerate ID may only be changed inside PDA enumerate
        // programming mode (Table 290 NOTE 9).
        if (!pda_enum_mode)
          prot("PDA Enumerate ID set outside PDA enumerate programming mode");
        else pda_enum_id = d.op[3:0];
        return;
      end
      MPCF_PDA_SEL_ID: begin pda_sel_id = d.op[3:0]; return; end
      default: ;
    endcase

    if (f != MPCF_EXACT) return;

    case (d.op)
      MPC_SET_2N:      mr[MR2][2] = 1'b1;
      MPC_SET_1N:      mr[MR2][2] = 1'b0;

      MPC_DLL_RESET: begin
        if (dev_st == DS_INIT && !init_mr13)
          prot("DLL RESET before the MPC that sets MR13 tDLLK/tCCD_L (3.3.1 step 7)");
        init_dll_reset = 1'b1;
      end

      MPC_ZQCAL_START: begin
        if (dev_st == DS_INIT && !init_dll_reset)
          prot("ZQCal Start before MPC DLL RESET (3.3.1 step 7)");
        if (zq_busy)
          prot("ZQCal Start while tZQCAL is still running (4.23.1)");
        zq_busy       = 1'b1;
        t_zq_start    = cur_ck;
        init_zq_start = 1'b1;
      end

      MPC_ZQCAL_LATCH: begin
        if (!init_zq_start)
          prot("ZQCal Latch with no preceding ZQCal Start");
        else if (zq_busy)
          chk("tZQCAL", t_zq_start, T.tZQCAL, "ZQCal Start -> ZQCal Latch");
        zq_latching   = 1'b1;
        t_zq_latch    = cur_ck;
        init_zq_latch = 1'b1;
      end

      MPC_ENTER_CA_TRAIN, MPC_ENTER_CS_TRAIN: begin
        if (!init_zq_latch)
          prot($sformatf("%s entered before ZQCal completed (3.3.1 step 7)",
                         d.op == MPC_ENTER_CA_TRAIN ? "CA training"
                                                    : "CS training"));
        dev_st_saved = dev_st;
        cstm_idx     = 0;         // restart the group of four
        cs_low_run   = 0;
        dev_st = (d.op == MPC_ENTER_CA_TRAIN) ? DS_CA_TRAINING
                                              : DS_CS_TRAINING;
      end

      MPC_ENTER_PDA_ENUM: pda_enum_mode = 1'b1;
      MPC_EXIT_PDA_ENUM:  pda_enum_mode = 1'b0;

      // "Apply VrefCA, VrefCS and RTT_CA/CS/CK" commits everything that has
      // been sitting in shadow registers (Table 290 NOTE 8). Until it runs, an
      // MRR of those fields returns the applied value, not the shadow.
      MPC_APPLY_VREF_RTT: begin
        mr[MR11] = {1'b0, shadow_vrefca};
        mr[MR12] = {1'b0, shadow_vrefcs};
        mr[MR32] = shadow_rtt_ck;
        mr[MR33] = shadow_rtt_ca;
        mr[MR34] = shadow_rtt_park;
      end

      MPC_MANUAL_ECS: begin
        if (!mr[MR14][7])
          prot("Manual ECS MPC issued with MR14 OP[7]=0 (manual ECS disabled)");
        else begin
          chk("tECSc", t_ecs, T.tECSc, "ECS -> ECS");
          t_ecs = cur_ck;
          ecs_step();
        end
      end

      MPC_EXIT_CS_TRAIN: begin
        dev_st    = dev_st_saved;
        train_drv = 1'b0;
      end

      default: ;   // remaining MPC opcodes are register writes, handled above
    endcase
    refresh_mr_views();
  endtask

  // =========================================================================
  // CA bus sampling
  // =========================================================================
  decoded_t d;

  always @(CK_t) begin
    ddr5_cmd_e c;
    int        off, col;
    longint unsigned k;

    if (CK_t && RESET_n) begin
      ck_cnt = ck_cnt + 1;

      // ---- reset exit opens the configuration phase ----
      if (dev_st == DS_RESET) begin
        dev_st       = DS_INIT;
        t_reset_exit = ck_cnt;
        t_cfg_ok     = ck_cnt + longint'(init_wait_ck());
      end

      // ---- ZQ calibration windows close ----
      if (zq_busy && (ck_cnt - t_zq_start) >= longint'(T.tZQCAL))
        zq_busy = 1'b0;
      if (zq_latching && (ck_cnt - t_zq_latch) >= longint'(T.tZQLAT)) begin
        zq_latching = 1'b0;
        // Calibration completing is what releases the part from configuration
        // into normal operation (3.3.1 step 9).
        if (dev_st == DS_INIT && init_zq_latch) begin
          dev_st = DS_NORMAL;
          if (VERBOSE)
            $display("%0t [%s] initialisation complete", $time, DEV_NAME);
        end
      end

      if (!alert_n_r && (ck_cnt - t_alert) >= longint'(ALERT_PW_CK))
        alert_n_r = 1'b1;

      check_refi();
      training_ck_edge();

      // In CA training the CA bus carries training samples, not commands, and
      // CS_n assertion is the sample trigger (4.19.3). Nothing is decoded.
      if (dev_st == DS_CA_TRAINING) begin
        // nothing further this cycle
      end
      else if (wait2) begin
        cur_ck = c1_ck;      // spacing is measured from the first CA cycle
        // ---- second cycle of a 2-cycle command ----
        wait2 = 1'b0;
        d = d_clear();
        d.cmd = c1_cmd;
        d.bl  = 16;

        // NOTE 11: a 2-cycle command with no ODT control is abandoned if CS_n
        // is low again on the second cycle.
        if (!CS_n && (c1_cmd == CMD_ACT || c1_cmd == CMD_MRW ||
                      c1_cmd == CMD_WRP)) begin
          prot($sformatf("%s aborted: CS_n low on 2nd cycle",
                         cmd_name(c1_cmd)));
        end
        else begin
          case (c1_cmd)
            CMD_ACT: begin
              d.bg   = int'(c1_ca[8 +: BG_BITS]);
              d.ba   = int'(c1_ca[6 +: BA_BITS]);
              d.bank = bank_of(d.bg, d.ba);
              // R0~R3 on cycle 1 CA[5:2], R4~R17 on cycle 2 CA[13:0]
              d.row  = int'({CA[ROW_BITS-5:0], c1_ca[5:2]});
              do_act(d);
            end
            CMD_WR, CMD_WRP: begin
              d.bg   = int'(c1_ca[8 +: BG_BITS]);
              d.ba   = int'(c1_ca[6 +: BA_BITS]);
              d.bank = bank_of(d.bg, d.ba);
              // C3~C10 on cycle 2 CA[8:1]; C2~C0 are not transferred for WR.
              d.col  = int'({CA[8:1], 3'b000});
              d.cstart = 4'b0000;
              d.ap   = (CA[10] == 1'b0);          // CA10 = AP (L = auto-pre)
              d.bl   = (c1_ca[5] == 1'b0) ? 8 : 16;  // CA5 BL* on cycle 1
              d.cmd  = d.ap ? CMD_WRA : CMD_WR;
              do_write(d);
            end
            CMD_RD: begin
              d.bg   = int'(c1_ca[8 +: BG_BITS]);
              d.ba   = int'(c1_ca[6 +: BA_BITS]);
              d.bank = bank_of(d.bg, d.ba);
              // C2~C10 on cycle 2 CA[8:0]
              d.col    = int'({CA[8:0], 2'b00});
              d.cstart = {CA[1], CA[0], 2'b00};   // {C3,C2,x,x}
              d.ap     = (CA[10] == 1'b0);
              d.bl     = (c1_ca[5] == 1'b0) ? 8 : 16;
              d.cmd    = d.ap ? CMD_RDA : CMD_RD;
              do_read(d);
            end
            CMD_MRW: begin
              d.mra = c1_ca[5 +: MRA_BITS];
              d.op  = CA[0 +: OP_BITS];
              if (CA[10] == 1'b0) do_mrw(d);      // CW=L: execute (NOTE 13)
            end
            CMD_MRR: begin
              d.mra = c1_ca[5 +: MRA_BITS];
              do_mrr(d);
            end
            default: ;
          endcase
          cmd_count++;
          if (VERBOSE)
            $display("%0t [%s] ck=%0d %s bank=%0d row=%0d col=%0d bl=%0d ap=%0b",
                     $time, DEV_NAME, ck_cnt, cmd_name(d.cmd), d.bank, d.row,
                     d.col, d.bl, d.ap);
        end
      end
      else if (!CS_n) begin
        // ---- first (or only) cycle ----
        cur_ck = ck_cnt;
        c = decode_cmd1(CA);
        if (c == CMD_NOP && dev_st == DS_POWER_DOWN) c = CMD_PDX;

        // Self-refresh exit is signalled by asserting CS_n, not by a command
        // encoding: the assertion itself wakes the part and is consumed by it.
        if (dev_st == DS_SELF_REFRESH) begin
          chk("tCKSRE", t_sre, T.tCKSRE, "SRE -> self-refresh exit");
          t_sr_exit = ck_cnt;
          dev_st    = DS_NORMAL;
          if (VERBOSE)
            $display("%0t [%s] self-refresh exit", $time, DEV_NAME);
        end
        else if (!check_cmd_legal(c)) begin
          // rejected: nothing executes, and a two-cycle command does not arm
        end
        else begin
        check_exit_windows(c);
        if (is_two_cycle(c)) begin
          c1_cmd = c;
          c1_ca  = CA;
          c1_ck  = ck_cnt;
          wait2  = 1'b1;
        end
        else begin
          d = d_clear();
          d.cmd = c;
          d.bl  = 16;
          d.bg  = int'(CA[8 +: BG_BITS]);
          d.ba  = int'(CA[6 +: BA_BITS]);
          d.bank = bank_of(d.bg, d.ba);
          d.op  = CA[5 +: OP_BITS];

          case (c)
            CMD_PREab, CMD_PREsb, CMD_PREpb: do_precharge(d, c);
            CMD_REFab, CMD_REFsb,
            CMD_RFMab, CMD_RFMsb:            do_refresh(d, c);
            CMD_MPC:                         do_mpc(d);
            CMD_SRE, CMD_SREF: begin
              // Self refresh needs every bank precharged; the DRAM refuses to
              // hold an open row across it.
              for (int i = 0; i < N_BANKS; i++)
                if (bank_st[i] != BS_IDLE)
                  prot($sformatf("SRE with bank %0d not precharged", i));
              chk("tRFC1", t_ref_ab, cfg_fgr_mode ? T.tRFC2 : T.tRFC1,
                  "REFab -> SRE");
              t_sre  = cur_ck;
              dev_st = DS_SELF_REFRESH;
            end
            CMD_PDE: begin
              t_pde  = cur_ck;
              dev_st = DS_POWER_DOWN;
            end
            CMD_PDX: begin
              chk("tCPDED", t_pde, T.tCPDED, "PDE -> PDX");
              t_pd_exit = cur_ck;
              dev_st    = DS_NORMAL;
            end
            CMD_VREFCA: shadow_vrefca = CA[5 +: 7];
            CMD_VREFCS: shadow_vrefcs = CA[5 +: 7];
            CMD_NOP, CMD_DES: ;
            CMD_RFU: prot($sformatf("RFU command encoding CA=0x%04h", CA));
            default: ;
          endcase

          if (c != CMD_NOP && c != CMD_DES) begin
            cmd_count++;
            if (VERBOSE)
              $display("%0t [%s] ck=%0d %s bank=%0d", $time, DEV_NAME,
                       ck_cnt, cmd_name(c), d.bank);
          end
        end
        end
      end

      // ---- retire pending precharges whose tRP window has opened ----
      for (int i = 0; i < N_BANKS; i++)
        if (bank_st[i] == BS_PRECHARGING && ck_cnt >= t_pre[i])
          close_bank(i);

      // ---- launch bursts whose RL / WL has elapsed ----
      // Read preamble: the DRAM drives DQS for the MR8 OP[2:0] duration ahead
      // of the burst so the PHY has something to gate on. DQ stays high-Z.
      if (rd_pend.valid && ck_cnt == rd_pre_ck) begin
        rd_pre_active = 1'b1;
        dqs_out       = 1'b0;
      end
      if (rd_pend.valid && ck_cnt == rd_pend.launch_ck) begin
        rd_driving    = 1'b1;
        rd_pre_active = 1'b0;
        rd_beat       = 0;
        rd_nbeats     = rd_pend.nbeats;
        rd_pend.valid = 1'b0;
      end
      if (wr_pend.valid && ck_cnt == wr_pend.launch_ck) begin
        // dqs_run is updated at the end of this block, so here it still counts
        // only the cycles before the burst -- which is the preamble.
        pre_len     = dqs_run;
        if (CHECK && pre_len < wr_preamble_ck_of(mr[MR8_ADDR][4:3]))
          viol("tWPRE",
               $sformatf("DQS was driven for %0d nCK before the burst, MR8 asks for %0d",
                         pre_len, wr_preamble_ck_of(mr[MR8_ADDR][4:3])));
        wr_open     = 1'b1;
        wr_seq      = wr_seq + 1;
        // Hold the window a little past the burst so a late DQS edge still
        // lands; the beat counter, not the window, terminates the capture.
        wr_close_ck = ck_cnt + longint'(wr_pend.nbeats/2) + 3;
      end
      if (wr_open && ck_cnt >= wr_close_ck) begin
        wr_open       = 1'b0;
        wr_pend.valid = 1'b0;
      end

      // DQS is a differential pair, so it is being driven exactly when its two
      // legs disagree. Testing DQS_t against 1'bz instead looks equivalent but
      // is not: a resolved tristate net does not compare reliably against Z.
      if (DQS_t !== DQS_c) dqs_run = dqs_run + 1;
      else                 dqs_run = 0;
    end  // rising edge, out of reset

    // -----------------------------------------------------------------------
    // DQ / DQS datapath — one beat per CK edge, two beats per tCK.
    // Reads drive DQS edge-aligned with the data, as DDR5 does. Writes are
    // captured on DQS in the block below.
    // Write preamble duration is checked against MR8 OP[4:3] where the burst
    // window opens. The read preamble is emitted below.
    // Not modelled: postamble length (MR8 OP[7:6]) and the exact preamble
    // toggle patterns -- only durations are enforced.
    // -----------------------------------------------------------------------
    if (RESET_n) begin
      if (rd_driving) begin
        if (rd_beat < rd_nbeats) begin
          dq_out  = rd_data[rd_beat];
          dqs_out = ~dqs_out;
          rd_beat = rd_beat + 1;
        end
        else rd_driving = 1'b0;
      end
    end
  end

  // =========================================================================
  // Write data capture — one beat per DQS edge while the window is open.
  // Any DQS edges before the window (the write preamble, tWPRE) are ignored
  // by construction, because the window opens exactly at WL.
  // =========================================================================
  always @(posedge DQS_t or negedge DQS_t) begin
    int off, col;
    longint unsigned k;
    if (wr_open && RESET_n) begin
      // Rearm on the window's sequence number rather than on having seen a
      // DQS edge while the window was shut: DQS goes high-Z between bursts and
      // a Z transition is not a reliable edge, so back-to-back bursts could
      // otherwise inherit the previous burst's beat counter.
      if (wr_seq_q != wr_seq) begin
        wr_beat      = 0;
        wr_seq_q     = wr_seq;
      end
      if (wr_beat < wr_pend.nbeats) begin
        wr_beats[wr_beat] = DQ;                   // kept for the CRC check
        if (DM_n === {(DQ_BITS/8){1'b1}}) begin   // DM_n low masks the beat
          off = burst_offset_wr(wr_beat, wr_pend.cstart, wr_pend.nbeats);
          col = {wr_pend.col_base[COL_BITS-1:4], off[3:0]};
          k   = mem_key(wr_pend.bank, wr_pend.row, col);
          mem[k] = DQ;
        end
        wr_beat = wr_beat + 1;
        // Gathering the whole block before recomputing the check bits is the
        // read-modify-write a partial (BC8) burst needs, and is a no-op for a
        // full one.
        if (wr_beat == wr_pend.nbeats && !wr_crc_enabled())
          ecc_update_block(wr_pend.bank, wr_pend.row,
                           wr_pend.col_base >> 4);
      end
      // With write CRC on, the burst carries two extra UI holding one CRC-8
      // per nibble.
      else if (wr_crc_enabled() && wr_beat < wr_pend.nbeats + 2) begin
        wr_crc_rx[wr_beat - wr_pend.nbeats] = DQ;
        wr_beat = wr_beat + 1;
        if (wr_beat == wr_pend.nbeats + 2) begin
          check_write_crc();
          ecc_update_block(wr_pend.bank, wr_pend.row,
                           wr_pend.col_base >> 4);
        end
      end
    end
  end

  // =========================================================================
  // Write levelling (4.21) -- the DRAM samples CK_t on the rising edge of DQS
  // and drives the result on every DQ, which is how the host walks DQS until
  // it finds the CK edge.
  // =========================================================================
  always @(posedge DQS_t) begin
    if (RESET_n && wl_training_on()) wl_val = CK_t;
  end


  // =========================================================================
  // Backdoor access for testbenches
  // =========================================================================
  task automatic backdoor_write(input int bank, input int row, input int col,
                                input logic [DQ_BITS-1:0] data);
    mem[mem_key(bank, row, col)] = data;
  endtask

  function automatic logic [DQ_BITS-1:0] backdoor_read(input int bank,
                                                       input int row,
                                                       input int col);
    longint unsigned k;
    k = mem_key(bank, row, col);
    return mem.exists(k) ? mem[k] : {DQ_BITS{1'bx}};
  endfunction

  function automatic int error_count();
    return err_count;
  endfunction

  function automatic int  device_state();   return int'(dev_st);   endfunction
  function automatic logic [3:0] pda_id();  return pda_enum_id;    endfunction

endmodule
