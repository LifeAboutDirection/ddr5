package rmc_pkg;

  // ---- core widths (compile-time params, override via `define / tool config) ----
  parameter int GC_WIDTH        = 32;
  parameter int ADDR_WIDTH      = 32;
  parameter int AXI_ID_WIDTH    = 8;
  parameter int DATA_WIDTH      = 64;
  parameter int STRB_WIDTH      = DATA_WIDTH/8;

  parameter int CH_BITS         = 0;   // anchor: single channel
  parameter int RANK_BITS       = 0;   // anchor: single rank
  parameter int BG_BITS         = 2;
  parameter int BANK_BITS       = 2;
  parameter int ROW_BITS        = 17;
  parameter int COL_BITS        = 10;

  parameter int N_RANKS         = 1;
  parameter int N_BG            = (1 << BG_BITS);
  parameter int N_BANKS         = N_BG * (1 << BANK_BITS);

  parameter int N_WR_ENTRIES    = 64;   // TODO: lock 64 vs 96, see review note
  parameter int N_RD_ENTRIES    = 32;
  parameter int WR_BUF_DEPTH    = N_WR_ENTRIES;

  parameter int STATUS_WIDTH    = 2;
  parameter int TIMING_WIDTH    = 16;
  parameter int PARAM_ID_WIDTH  = 8;
  parameter int FAW_DEPTH       = 4;
  parameter int FIFO_DEPTH      = 16;

  parameter int CREDIT_WIDTH    = 4;    // leaky bucket 0..15, TODO confirm
  parameter int RAA_WIDTH       = 4;    // TODO confirm vs RAAIMT max

  parameter int BANK_STATE_WIDTH  = 3;
  parameter int RANK_STATE_WIDTH  = 3;
  parameter int GLOBAL_STATE_WIDTH = 3;

  // ---- derived timing thresholds (TODO: move to CSR-derived, not literal) ----
  parameter int RD_STARVATION_THR = 12480;
  parameter int WR_STARVATION_THR = 37440;
  parameter int WR_HIGH_WM        = 16;
  parameter int WR_LOW_WM         = 4;
  parameter int AGE_THR2          = 256;

  // ---- bank FSM state encoding ----
  typedef enum logic [BANK_STATE_WIDTH-1:0] {
    BANK_IDLE          = 3'b000,
    BANK_ACTIVATING    = 3'b001,
    BANK_ACTIVE        = 3'b010,
    BANK_PRECHARGING   = 3'b011,
    BANK_REFRESHING_SB = 3'b100,
    BANK_RFM_ACTIVE    = 3'b101,
    BANK_POWER_DOWN    = 3'b110,
    BANK_SELF_REFRESH  = 3'b111
  } bank_state_e;

  typedef enum logic [RANK_STATE_WIDTH-1:0] {
    RANK_NORMAL        = 3'b000,
    RANK_REFAB_ACTIVE  = 3'b001,
    RANK_ZQCAL_ACTIVE  = 3'b010,
    RANK_POWER_DOWN    = 3'b011,
    RANK_SELF_REFRESH  = 3'b100
  } rank_state_e;

  typedef enum logic [STATUS_WIDTH-1:0] {
    REQ_PENDING = 2'b00,
    REQ_ISSUED  = 2'b01,
    REQ_DONE    = 2'b10,
    REQ_ERROR   = 2'b11
  } req_status_e;

  // ---- status reg structs (§7) ----
  typedef struct packed {
    logic                          valid;
    req_status_e                   status;
    logic [GC_WIDTH-1:0]           age;
  } wr_status_t;

  typedef struct packed {
    logic                          valid;
    req_status_e                   status;
    logic [GC_WIDTH-1:0]           age;
    logic                          merge_pending;
    logic [$clog2(WR_BUF_DEPTH)-1:0] wdb_entry_idx;
  } rd_status_t;

  // ---- per-bank FSM table row (§9A) ----
  typedef struct packed {
    bank_state_e            state;
    logic [ROW_BITS-1:0]    row_open;
    logic [GC_WIDTH-1:0]    next_cas;
    logic [GC_WIDTH-1:0]    next_pre;
    logic [GC_WIDTH-1:0]    next_act;
    logic [GC_WIDTH-1:0]    next_ref;
    logic                   can_cas;
    logic                   can_pre;
    logic                   can_act;
    logic                   can_ref;
    logic                   ref_pending;
  } bank_fsm_t;

endpackage : rmc_pkg
