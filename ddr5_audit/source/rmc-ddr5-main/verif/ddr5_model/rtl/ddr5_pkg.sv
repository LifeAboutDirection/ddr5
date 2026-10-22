// ---------------------------------------------------------------------------
// ddr5_pkg.sv — DDR5 SDRAM device model: organization, command encoding, types
//
// Encodings transcribed from JEDEC JESD79-5:
//   Table 4..8   — Addressing tables (organization per density/width)
//   Table 241    — Command Truth Table
//   Table 242/3  — Burst Type and Burst Order
//   Table 290    — MPC Command Definition for OP[7:0]
//
// The model is checker-first: it decodes the CA bus exactly as a DRAM would and
// reports any protocol or timing violation as a simulation error.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

package ddr5_pkg;

  // -------------------------------------------------------------------------
  // Pin widths (fixed by the standard)
  // -------------------------------------------------------------------------
  parameter int CA_BITS      = 14;   // CA[13:0]
  parameter int MRA_BITS     = 8;    // MRA[7:0]
  parameter int OP_BITS      = 8;    // OP[7:0]
  parameter int N_MR         = 256;  // MR0..MR255

  // -------------------------------------------------------------------------
  // Device organization — defaults are the 32 Gb x16 part (JESD79-5 Table 7).
  //   4 BG x 4 banks = 16 banks, R0~R16, C0~C9, 2 KB page.
  // This is exactly the rmc anchor: one device == single channel, 4 GB.
  // Override via the device module's parameters for x4 / x8 / other densities.
  // -------------------------------------------------------------------------
  parameter int DEF_DQ_BITS   = 16;
  parameter int DEF_BG_BITS   = 2;   // BG0~BG1  (x16). x4/x8 use 3.
  parameter int DEF_BA_BITS   = 2;   // BA0~BA1
  parameter int DEF_ROW_BITS  = 17;  // R0~R16   (32 Gb)
  parameter int DEF_COL_BITS  = 10;  // C0~C9    (x16). x4 uses 11 (C0~C10).

  // -------------------------------------------------------------------------
  // Commands (JESD79-5 Table 241)
  // -------------------------------------------------------------------------
  typedef enum int {
    CMD_DES,     // CS_n high
    CMD_NOP,
    CMD_ACT,
    CMD_RD,   CMD_RDA,
    CMD_WR,   CMD_WRA,
    CMD_WRP,  CMD_WRPA,
    CMD_MRW,  CMD_MRR,
    CMD_REFab, CMD_REFsb,
    CMD_RFMab, CMD_RFMsb,
    CMD_PREab, CMD_PREsb, CMD_PREpb,
    CMD_SRE,  CMD_SREF,
    CMD_PDE,  CMD_PDX,
    CMD_MPC,
    CMD_VREFCA, CMD_VREFCS,
    CMD_RFU
  } ddr5_cmd_e;

  function automatic string cmd_name(ddr5_cmd_e c);
    case (c)
      CMD_DES:    return "DES";     CMD_NOP:    return "NOP";
      CMD_ACT:    return "ACT";
      CMD_RD:     return "RD";      CMD_RDA:    return "RDA";
      CMD_WR:     return "WR";      CMD_WRA:    return "WRA";
      CMD_WRP:    return "WRP";     CMD_WRPA:   return "WRPA";
      CMD_MRW:    return "MRW";     CMD_MRR:    return "MRR";
      CMD_REFab:  return "REFab";   CMD_REFsb:  return "REFsb";
      CMD_RFMab:  return "RFMab";   CMD_RFMsb:  return "RFMsb";
      CMD_PREab:  return "PREab";   CMD_PREsb:  return "PREsb";
      CMD_PREpb:  return "PREpb";
      CMD_SRE:    return "SRE";     CMD_SREF:   return "SREF";
      CMD_PDE:    return "PDE";     CMD_PDX:    return "PDX";
      CMD_MPC:    return "MPC";
      CMD_VREFCA: return "VrefCA";  CMD_VREFCS: return "VrefCS";
      default:    return "RFU";
    endcase
  endfunction

  // True for the 2-cycle commands. Per Table 241 the encoding is arranged so
  // CA1 alone separates 1-cycle from 2-cycle commands, with ACT (CA0=L) apart.
  function automatic bit is_two_cycle(ddr5_cmd_e c);
    case (c)
      CMD_ACT, CMD_RD, CMD_RDA, CMD_WR, CMD_WRA,
      CMD_WRP, CMD_WRPA, CMD_MRW, CMD_MRR: return 1'b1;
      default:                             return 1'b0;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // First-cycle decode (CS_n asserted low).
  //   CA0=L                -> ACT   (2 cycle)
  //   CA0=H, CA1=L         -> 2-cycle group, selected by {CA4,CA3,CA2}
  //   CA0=H, CA1=H         -> 1-cycle group, selected by {CA4,CA3,CA2}
  // Sub-decode inside a group uses the later CA pins, as noted per case.
  // -------------------------------------------------------------------------
  function automatic ddr5_cmd_e decode_cmd1(input logic [CA_BITS-1:0] ca);
    logic [2:0] sel;
    sel = {ca[4], ca[3], ca[2]};

    if (ca[0] == 1'b0) return CMD_ACT;

    if (ca[1] == 1'b0) begin                   // ---- 2-cycle group ----
      // sel = {CA4,CA3,CA2}: MRW H,L,L | WRP L,H,L | WR H,H,L | MRR H,L,H
      //                      RD  H,H,H | all remaining encodings RFU
      case (sel)
        3'b001: return CMD_MRW;
        3'b010: return (ca[5] == 1'b1) ? CMD_WRP : CMD_RFU; // CA5 must be H
        3'b011: return CMD_WR;                 // WR vs WRA from 2nd cycle CA10
        3'b101: return CMD_MRR;
        3'b111: return CMD_RD;                 // RD vs RDA from 2nd cycle CA10
        default: return CMD_RFU;
      endcase
    end
    else begin                                 // ---- 1-cycle group ----
      // sel = {CA4,CA3,CA2}; see Table 241 rows in CA2/CA3/CA4 order:
      //   VrefCA/CS L,L,L | REF/RFM L,L,H | PREab/sb L,H,L | PREpb L,H,H
      //   RFU       H,L,L | SRE/PDE H,L,H | MPC       H,H,L | NOP/PDX H,H,H
      case (sel)
        3'b000: return (ca[12] == 1'b0) ? CMD_VREFCA : CMD_VREFCS;
        3'b100: begin                          // REF / RFM family
                  // CA9 : H = Refresh, L = Refresh Management
                  // CA10: L = all bank,  H = same bank
                  if (ca[9]) return ca[10] ? CMD_REFsb : CMD_REFab;
                  else       return ca[10] ? CMD_RFMsb : CMD_RFMab;
                end
        3'b010: return ca[10] ? CMD_PREsb : CMD_PREab;
        3'b110: return CMD_PREpb;
        3'b001: return CMD_RFU;
        3'b101: begin                          // SRE / SREF / PDE
                  if (ca[10] == 1'b1) return CMD_PDE;          // CA10=H
                  else                return ca[9] ? CMD_SRE   // CA9=H
                                                   : CMD_SREF; // CA9=L
                end
        3'b011: return CMD_MPC;
        3'b111: return CMD_NOP;   // NOP/PDX share an encoding; caller resolves
                                  // PDX by current power-down state.
        default: return CMD_RFU;
      endcase
    end
  endfunction

  // -------------------------------------------------------------------------
  // MPC opcodes (JESD79-5 Table 290). Exact 8-bit codes first, then the
  // ranged codes that carry a field in the low bits.
  // -------------------------------------------------------------------------
  parameter logic [7:0] MPC_EXIT_CS_TRAIN     = 8'b0000_0000;
  parameter logic [7:0] MPC_ENTER_CS_TRAIN    = 8'b0000_0001;
  parameter logic [7:0] MPC_DLL_RESET         = 8'b0000_0010;
  parameter logic [7:0] MPC_ENTER_CA_TRAIN    = 8'b0000_0011;
  parameter logic [7:0] MPC_ZQCAL_LATCH       = 8'b0000_0100;
  parameter logic [7:0] MPC_ZQCAL_START       = 8'b0000_0101;
  parameter logic [7:0] MPC_STOP_DQS_OSC      = 8'b0000_0110;
  parameter logic [7:0] MPC_START_DQS_OSC     = 8'b0000_0111;
  parameter logic [7:0] MPC_SET_2N            = 8'b0000_1000;
  parameter logic [7:0] MPC_SET_1N            = 8'b0000_1001;
  parameter logic [7:0] MPC_EXIT_PDA_ENUM     = 8'b0000_1010;
  parameter logic [7:0] MPC_ENTER_PDA_ENUM    = 8'b0000_1011;
  parameter logic [7:0] MPC_MANUAL_ECS        = 8'b0000_1100;
  parameter logic [7:0] MPC_APPLY_VREF_RTT    = 8'b0001_1111;

  typedef enum int {
    MPCF_EXACT, MPCF_RTT_CK_A, MPCF_RTT_CK_B, MPCF_RTT_CS_A, MPCF_RTT_CS_B,
    MPCF_RTT_CA_A, MPCF_RTT_CA_B, MPCF_DQS_RTT_PARK, MPCF_RTT_PARK,
    MPCF_PDA_ENUM_ID, MPCF_PDA_SEL_ID, MPCF_TDLLK_TCCDL, MPCF_RESERVED
  } mpc_field_e;

  // Classify the ranged MPC opcodes; MPCF_EXACT means "match against the
  // MPC_* constants above".
  function automatic mpc_field_e mpc_class(input logic [7:0] op);
    if (op[7:3] == 5'b0010_0) return MPCF_RTT_CK_A;
    if (op[7:3] == 5'b0010_1) return MPCF_RTT_CK_B;
    if (op[7:3] == 5'b0011_0) return MPCF_RTT_CS_A;
    if (op[7:3] == 5'b0011_1) return MPCF_RTT_CS_B;
    if (op[7:3] == 5'b0100_0) return MPCF_RTT_CA_A;
    if (op[7:3] == 5'b0100_1) return MPCF_RTT_CA_B;
    if (op[7:3] == 5'b0101_0) return MPCF_DQS_RTT_PARK;
    if (op[7:3] == 5'b0101_1) return MPCF_RTT_PARK;
    if (op[7:4] == 4'b0110)   return MPCF_PDA_ENUM_ID;
    if (op[7:4] == 4'b0111)   return MPCF_PDA_SEL_ID;
    if (op[7:4] == 4'b1000)   return MPCF_TDLLK_TCCDL;
    if (op <= MPC_MANUAL_ECS || op == MPC_APPLY_VREF_RTT) return MPCF_EXACT;
    return MPCF_RESERVED;
  endfunction

  // -------------------------------------------------------------------------
  // Mode registers used by the model core (JESD79-5 Table 24 and 3.5.x)
  // -------------------------------------------------------------------------
  parameter int MR0  = 0;    // OP[1:0] burst length, OP[6:2] CAS latency
  // MR2 (Table 320): OP[0] read preamble training, OP[1] write levelling
  // training, OP[2] 2N mode, OP[3] MPSM, OP[4] CS assertion duration,
  // OP[5] device-15 MPSM, OP[7] internal write timing.
  parameter int MR2  = 2;
  parameter int MR8_ADDR = 8;
  parameter int MR3  = 3;    // write recovery / RFU per rev
  parameter int MR4  = 4;    // OP[2:0] refresh rate, OP[3] 2x REF indicator,
                             // OP[4] refresh mode (0=tRFC1, 1=tRFC2/FGR)
  parameter int MR8  = 8;    // read/write preamble
  parameter int MR11 = 11;   // VrefCA calibration value
  parameter int MR12 = 12;   // VrefCS calibration value
  parameter int MR13 = 13;   // tCCD_L / tDLLK
  parameter int MR14 = 14;   // ECS mode, reset counters, row/code-word mode
  parameter int MR15 = 15;   // ECS error threshold count, auto ECS in SR
  parameter int MR16 = 16;   // EpRC row address R7:R0
  parameter int MR17 = 17;   // EpRC row address R15:R8
  parameter int MR18 = 18;   // EpRC BG/BA and R17:R16
  parameter int MR19 = 19;   // EpRC error count REC5:REC0
  parameter int MR20 = 20;   // ECS error counter EC
  parameter int MR25 = 25;   // read training pattern mode settings
  parameter int MR26 = 26;   // read pattern data0 / LFSR0 seed
  parameter int MR27 = 27;   // read pattern data1 / LFSR1 seed
  parameter int MR28 = 28;   // read pattern invert, lower byte
  parameter int MR29 = 29;   // read pattern invert, upper byte
  parameter int MR30 = 30;   // read LFSR assignments
  parameter int MR31 = 31;   // read training pattern address (no fields)
  parameter int MR32 = 32;   // RTT_CK
  parameter int MR33 = 33;   // RTT_CA / DQS_RTT_PARK
  parameter int MR34 = 34;   // RTT_PARK
  parameter int MR50 = 50;   // write/read CRC settings

  // MR8 preamble/postamble (Table 40)
  function automatic int wr_preamble_ck_of(input logic [1:0] code);
    case (code)
      2'b01:   return 2;    // 2 tCK, 0010 pattern (default)
      2'b10:   return 3;    // 3 tCK, 000010
      2'b11:   return 4;    // 4 tCK, 00001010
      default: return 2;    // 00B is reserved
    endcase
  endfunction

  function automatic int rd_preamble_ck_of(input logic [2:0] code);
    case (code)
      3'b000:  return 1;    // 1 tCK, 10
      3'b001:  return 2;    // 2 tCK, 0010
      3'b010:  return 2;    // 2 tCK, 1110 (DDR4 style)
      3'b011:  return 3;    // 3 tCK, 000010
      3'b100:  return 4;    // 4 tCK, 00001010
      default: return 2;    // 101B-111B reserved
    endcase
  endfunction

  // Read-training LFSR: 8-bit Galois, x^8 + x^6 + x^5 + x^4 + 1 (4.17.2)
  function automatic logic [7:0] lfsr8_next(input logic [7:0] s);
    logic fb;
    fb = s[0];
    return fb ? ({1'b0, s[7:1]} ^ 8'hB8) : {1'b0, s[7:1]};
  endfunction
  parameter int MR58 = 58;   // RFM required, RAAIMT, RAAMMT  (read only)
  parameter int MR59 = 59;   // RAA counter decrement per REF (read only)

  // -------------------------------------------------------------------------
  // Refresh management decode (JESD79-5 4.41)
  //
  // MR58 OP[0]    RFM required
  // MR58 OP[4:1]  RAAIMT  -- initial management threshold
  // MR58 OP[7:5]  RAAMMT  -- maximum management threshold, a multiple of RAAIMT
  // MR59 OP[7:6]  RAA decrement applied per REF command
  //
  // All three are read only and vendor specific; the device model takes them
  // as parameters and publishes them here for the controller to read via MRR.
  // -------------------------------------------------------------------------
  function automatic int raaimt_of(input logic [3:0] code, input bit fgr);
    int v;
    if (code < 4'd4 || code > 4'd10) return 0;    // RFU encodings
    v = 32 + (int'(code) - 4) * 8;                // 0100B=32 .. 1010B=80
    return fgr ? v/2 : v;
  endfunction

  function automatic int raammt_mult_of(input logic [2:0] code, input bit fgr);
    if (code < 3'd3 || code == 3'd7) return 0;    // RFU encodings
    return fgr ? 2*int'(code) : int'(code);       // 011B=3x .. 110B=6x
  endfunction

  // MR59 OP[7:6]: 00B = RAAIMT, 01B = RAAIMT * 0.5
  function automatic int raadec_of(input logic [1:0] code, input int raaimt);
    case (code)
      2'b00:   return raaimt;
      2'b01:   return raaimt/2;
      default: return raaimt;                     // 10B/11B are RFU
    endcase
  endfunction

  // MR0 OP[1:0] burst length (Table 26)
  parameter logic [1:0] BL_BL16     = 2'b00;
  parameter logic [1:0] BL_BC8_OTF  = 2'b01;
  parameter logic [1:0] BL_BL32     = 2'b10;
  parameter logic [1:0] BL_BL32_OTF = 2'b11;

  // MR15 OP[2:0] ECS error threshold count per Gb (Table 360)
  function automatic int ecs_threshold_of(input logic [2:0] code);
    case (code)
      3'b000: return 4;
      3'b001: return 16;
      3'b010: return 64;
      3'b011: return 256;      // default
      3'b100: return 1024;
      3'b101: return 4096;
      default: return 256;     // 110B / 111B are RFU
    endcase
  endfunction

  // Row Error Threshold Count, Table 363 -- fixed at 4.
  parameter int ECS_RETC = 4;

  // MR0 OP[6:2] CAS latency: code 0 -> RL 22, +2 per step (Table 26)
  function automatic int mr0_to_rl(input logic [4:0] code);
    return 22 + 2*int'(code);
  endfunction
  function automatic logic [4:0] rl_to_mr0(input int rl);
    return 5'((rl - 22) / 2);
  endfunction

  // -------------------------------------------------------------------------
  // Bank state
  // -------------------------------------------------------------------------
  typedef enum int {
    BS_IDLE,          // precharged
    BS_ACTIVE,        // row open
    BS_REFRESHING,    // REFsb / RFMsb in flight on this bank
    BS_PRECHARGING    // PRE issued, tRP not yet elapsed
  } bank_state_e;

  typedef enum int {
    DS_RESET, DS_INIT, DS_NORMAL, DS_POWER_DOWN, DS_SELF_REFRESH,
    DS_CA_TRAINING, DS_CS_TRAINING
  } dev_state_e;

  // -------------------------------------------------------------------------
  // Burst order — sequential only (interleaved is not supported in DDR5).
  //   Read  : JESD79-5 Table 242. C3/C2 select the starting 4-beat group; the
  //           group index for beat n is (n/4) XOR {C3,C2} for BL16, and
  //           (n/4) XOR C2 inside the C3-selected half for BC8.
  //   Write : JESD79-5 Table 243. BL16 always starts at 0; BC8 uses C3 only,
  //           C2/C1/C0 are ignored by the input buffer.
  // Both return the burst-internal beat offset 0..15.
  // -------------------------------------------------------------------------
  function automatic int burst_offset_rd(input int beat,          // 0..BL-1
                                         input logic [3:0] cstart, // {C3,C2,C1,C0}
                                         input int bl);            // 8 or 16
    int grp, pos;
    pos = beat % 4;
    grp = beat / 4;
    if (bl == 8) return int'(cstart[3])*8 + ((grp ^ int'(cstart[2])) % 2)*4 + pos;
    return ((grp ^ int'(cstart[3:2])) % 4)*4 + pos;
  endfunction

  function automatic int burst_offset_wr(input int beat,
                                         input logic [3:0] cstart,
                                         input int bl);
    if (bl == 8) return int'(cstart[3])*8 + beat;
    return beat;
  endfunction

  // -------------------------------------------------------------------------
  // CA encoders — the exact inverse of decode_cmd1 and the operand fields in
  // Table 241. A command emitter (testbench today, the RMC emit stage later)
  // builds its CA phases with these so encoder and decoder can never drift.
  //
  // `bgw` / `baw` are the BG / BA field widths of the target device (2 or 3,
  // and 2). One-cycle commands return their single phase from the *1 function;
  // two-cycle commands use *1 for the first phase and *2 for the second.
  // -------------------------------------------------------------------------
  function automatic logic [CA_BITS-1:0] enc_act1(input int bg, input int ba,
                                                  input int row,
                                                  input int bgw, input int baw);
    logic [CA_BITS-1:0] c;
    c      = '0;
    c[0]   = 1'b0;  c[1] = 1'b0;             // ACT
    c[5:2] = row[3:0];                       // R0~R3
    for (int i = 0; i < baw; i++) c[6+i]        = ba[i];
    for (int i = 0; i < bgw; i++) c[8+i]        = bg[i];
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_act2(input int row,
                                                  input int row_bits);
    logic [CA_BITS-1:0] c;
    c = '0;
    for (int i = 0; i < row_bits-4; i++) c[i] = row[i+4];   // R4 and up
    return c;
  endfunction

  // sel = {CA4,CA3,CA2}: WR = H,H,L ; RD = H,H,H ; MRW = H,L,L ; MRR = H,L,H
  function automatic logic [CA_BITS-1:0] enc_cas1(input bit is_rd,
                                                  input int bg, input int ba,
                                                  input bit bl16,
                                                  input int bgw, input int baw);
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b0;               // 2-cycle group
    c[2] = 1'b1;  c[3] = 1'b1;  c[4] = is_rd;
    c[5] = bl16;                             // CA5 = BL*, H selects BL16
    for (int i = 0; i < baw; i++) c[6+i] = ba[i];
    for (int i = 0; i < bgw; i++) c[8+i] = bg[i];
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_cas2(input bit is_rd,
                                                  input int col, input bit ap);
    logic [CA_BITS-1:0] c;
    c = '0;
    if (is_rd) c[8:0] = col[10:2];           // RD carries C2~C10
    else       c[8:1] = col[10:3];           // WR carries C3~C10
    c[10] = ap ? 1'b0 : 1'b1;                // CA10 = AP, L = auto precharge
    if (!is_rd) c[11] = 1'b1;                // WR_partial = H (full write)
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_mrw1(input logic [MRA_BITS-1:0] mra);
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b0;
    c[2] = 1'b1;  c[3] = 1'b0;  c[4] = 1'b0;      // sel = MRW
    c[5 +: MRA_BITS] = mra;
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_mrw2(input logic [OP_BITS-1:0] op);
    logic [CA_BITS-1:0] c;
    c = '0;
    c[0 +: OP_BITS] = op;
    c[10] = 1'b0;                                 // CW = L : execute
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_mrr1(input logic [MRA_BITS-1:0] mra);
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b0;
    c[2] = 1'b1;  c[3] = 1'b0;  c[4] = 1'b1;      // sel = MRR
    c[5 +: MRA_BITS] = mra;
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_mrr2();
    logic [CA_BITS-1:0] c;
    c = '0;
    c[0] = 1'b0;  c[1] = 1'b0;                    // NOTE 25: burst ordering
    return c;
  endfunction

  // One-cycle commands. sel = {CA4,CA3,CA2}.
  function automatic logic [CA_BITS-1:0] enc_pre_pb(input int bg, input int ba,
                                                    input int bgw, input int baw);
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b0;  c[3] = 1'b1;  c[4] = 1'b1;      // sel = PREpb
    for (int i = 0; i < baw; i++) c[6+i] = ba[i];
    for (int i = 0; i < bgw; i++) c[8+i] = bg[i];
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_pre_ab();
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b0;  c[3] = 1'b1;  c[4] = 1'b0;      // sel = PREab/sb
    c[10] = 1'b0;                                 // CA10 = L : all bank
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_ref_ab();
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b0;  c[3] = 1'b0;  c[4] = 1'b1;      // sel = REF/RFM
    c[9]  = 1'b1;                                 // CA9  = H : Refresh
    c[10] = 1'b0;                                 // CA10 = L : all bank
    return c;
  endfunction

  // Power-down entry: sel = {CA4,CA3,CA2} = H,L,H with CA10 = H
  function automatic logic [CA_BITS-1:0] enc_pde();
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b1;  c[3] = 1'b0;  c[4] = 1'b1;
    c[10] = 1'b1;                                 // CA10 = H : power down
    c[11] = 1'b0;                                 // ODT = L
    return c;
  endfunction

  // Self-refresh entry: same sel, CA10 = L and CA9 = H
  function automatic logic [CA_BITS-1:0] enc_sre();
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b1;  c[3] = 1'b0;  c[4] = 1'b1;
    c[9]  = 1'b1;                                 // CA9  = H : SRE
    c[10] = 1'b0;
    return c;
  endfunction

  // VrefCA / VrefCS: sel = {CA4,CA3,CA2} = L,L,L ; OP[6:0] on CA[11:5];
  // CA12 picks CA (L) or CS (H).
  function automatic logic [CA_BITS-1:0] enc_vref(input bit is_cs,
                                                  input logic [6:0] op);
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b0;  c[3] = 1'b0;  c[4] = 1'b0;
    c[5 +: 7] = op;
    c[12] = is_cs;
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_vrefca(input logic [6:0] op);
    return enc_vref(1'b0, op);
  endfunction

  function automatic logic [CA_BITS-1:0] enc_vrefcs(input logic [6:0] op);
    return enc_vref(1'b1, op);
  endfunction

  // MPC: sel = {CA4,CA3,CA2} = H,H,L ; OP[7:0] on CA[12:5]
  function automatic logic [CA_BITS-1:0] enc_mpc(input logic [OP_BITS-1:0] op);
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b1;  c[3] = 1'b1;  c[4] = 1'b0;
    c[5 +: OP_BITS] = op;
    return c;
  endfunction

  function automatic logic [CA_BITS-1:0] enc_nop();
    logic [CA_BITS-1:0] c;
    c    = '0;
    c[0] = 1'b1;  c[1] = 1'b1;
    c[2] = 1'b1;  c[3] = 1'b1;  c[4] = 1'b1;      // sel = NOP/PDX
    return c;
  endfunction

endpackage : ddr5_pkg
