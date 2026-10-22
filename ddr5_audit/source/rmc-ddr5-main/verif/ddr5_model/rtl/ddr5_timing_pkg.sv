// ---------------------------------------------------------------------------
// ddr5_timing_pkg.sv — speed-bin timing tables for the DDR5 device model
//
// All checks in the model are done in whole CK cycles (nCK). JEDEC states many
// parameters as max(nCK floor, ns floor); that max is resolved here, once, at
// elaboration, so the runtime checker is a plain integer compare.
//
// Sources:
//   JESD79-5 Table 282  — tRFC1/tRFC2/tRFCsb by device density
//   JESD79-5 Table 281  — tREFI (3.9 us baseline, 8192 REF per 32 ms tREF)
//   rmc_theory/docs/datapath_busy_timing.md §1 — the DDR5-4800B column, already
//   cross-checked against JESD79-5 (marked "ok = JEDEC-locked, pulled
//   2026-07-16"). The "toy" bin below is the 5 ns/200 MHz column from the same
//   table, kept so waveforms stay readable and RMC_Handoff §18 cross-checks hold.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

package ddr5_timing_pkg;

  typedef enum int {
    BIN_TOY_200MHZ,   // 5 ns tCK, DDR4-scaled numbers — debug/waveform bin
    BIN_DDR5_4800B    // 4800 MT/s, tCK = 0.4167 ns
  } speed_bin_e;

  typedef enum int {
    DEN_8G, DEN_16G, DEN_24G, DEN_32G
  } density_e;

  typedef struct {
    real tCK_ns;
    int  BL;          // default burst length
    int  RL;          // CAS latency, = CL
    int  WL;          // = RL - 2 (JESD79-5 Table 26 NOTE 2)
    // --- core bank timings ---
    int  tRCD;
    int  tRP;
    int  tRAS;
    int  tRC;
    int  tRTP;
    int  tWR;         // write recovery, measured from end of write data
    // --- inter-command spacing ---
    int  tRRD_S;
    int  tRRD_L;
    int  tFAW;
    int  tCCD_S;
    int  tCCD_L;
    int  tCCD_L_WR;
    int  tCCD_L_WR2;
    int  tWTR_S;      // from end of write data
    int  tWTR_L;      // from end of write data
    int  tPPD;
    int  tRTW;        // derived: RL + BL/2 - WL + tWPRE
    // --- preamble ---
    int  tWPRE;
    int  tRPRE;
    // --- refresh ---
    int  tRFC1;
    int  tRFC2;
    int  tRFCsb;
    int  tREFI;
    // --- refresh management (JESD79-5 4.41, Table 378: tRFM == tRFC) ---
    int  tRFM1;
    int  tRFM2;
    int  tRFMsb;
    int  refi_stretch;   // max REFab interval, as a multiple of tREFI
    // --- initialisation (Table 11) ---
    int  tINIT3;
    int  tINIT4;
    int  tINIT5;
    int  tXPR;
    // --- ECS (Table 357) ---
    int  tECSc;
    // --- mode register / misc ---
    int  tMRW;
    int  tMRR;
    int  tMRD;
    int  tZQCAL;
    int  tZQLAT;
    int  tXP;
    int  tXS;
    int  tCPDED;
    int  tCKSRE;
    int  tCKSRX;
  } ddr5_timing_t;

  function automatic int ceil_ck(input real ns, input real tCK_ns);
    return int'($ceil(ns / tCK_ns - 1.0e-9));
  endfunction

  function automatic int max2(input int a, input int b);
    return (a > b) ? a : b;
  endfunction

  // tRFC family, JESD79-5 Table 282. The 24 Gb and 32 Gb columns are literally
  // "TBD" in this revision of the standard, so they fall back to the 16 Gb
  // numbers and warn. Replace when moving to a revision that pins them.
  function automatic void rfc_ns(input density_e den,
                                 output real t1, output real t2, output real tsb);
    case (den)
      DEN_8G:  begin t1 = 195.0; t2 = 130.0; tsb = 115.0; end
      DEN_16G: begin t1 = 295.0; t2 = 160.0; tsb = 130.0; end
      default: begin t1 = 295.0; t2 = 160.0; tsb = 130.0; end // 24G/32G: TBD
    endcase
  endfunction

  function automatic ddr5_timing_t get_timing(input speed_bin_e bin,
                                              input density_e   den);
    ddr5_timing_t t;
    real r1, r2, rsb;
    rfc_ns(den, r1, r2, rsb);

    case (bin)
      // ---------------------------------------------------------------------
      // Toy 200 MHz bin — DDR4-scaled, matches datapath_busy_timing.md "Toy"
      // column and RMC_Handoff §18. Not a JEDEC bin; debug only.
      // ---------------------------------------------------------------------
      BIN_TOY_200MHZ: begin
        t.tCK_ns     = 5.0;
        t.RL         = 3;    t.WL         = 1;
        t.tRCD       = 4;    t.tRP        = 4;    t.tRAS      = 7;
        t.tRC        = 11;   t.tRTP       = 12;   t.tWR       = 6;
        t.tRRD_S     = 8;    t.tRRD_L     = 8;    t.tFAW      = 32;
        t.tCCD_S     = 8;    t.tCCD_L     = 8;
        t.tCCD_L_WR  = 32;   t.tCCD_L_WR2 = 16;
        t.tWTR_S     = 4;    t.tWTR_L     = 16;   t.tPPD      = 2;
        t.tWPRE      = 1;    t.tRPRE      = 1;
      end

      // ---------------------------------------------------------------------
      // DDR5-4800B — 40-39-39 bin, tCK = 0.4167 ns.
      // ---------------------------------------------------------------------
      default: begin
        t.tCK_ns     = 0.4167;
        t.RL         = 40;   t.WL         = 38;
        t.tRCD       = 39;   t.tRP        = 39;   t.tRAS      = 77;
        t.tRC        = 116;  t.tRTP       = 18;   t.tWR       = 72;
        t.tRRD_S     = 8;    t.tRRD_L     = 12;   t.tFAW      = 32;
        t.tCCD_S     = 8;    t.tCCD_L     = 12;
        t.tCCD_L_WR  = 32;   t.tCCD_L_WR2 = 16;
        t.tWTR_S     = 6;    t.tWTR_L     = 24;   t.tPPD      = 2;
        t.tWPRE      = 2;    t.tRPRE      = 2;
      end
    endcase

    t.BL    = 16;
    // Read-to-write command spacing so the write preamble clears the read
    // burst on DQ: RL + BL/2 - WL + tWPRE. See datapath_busy_timing.md §2.
    t.tRTW  = t.RL + (t.BL/2) - t.WL + t.tWPRE;

    t.tRFC1  = ceil_ck(r1,     t.tCK_ns);
    t.tRFC2  = ceil_ck(r2,     t.tCK_ns);
    t.tRFCsb = ceil_ck(rsb,    t.tCK_ns);
    t.tREFI  = ceil_ck(3900.0, t.tCK_ns);   // 3.9 us, Table 281

    // tRFM,min is tRFC,min for the matching refresh operation (Table 378).
    t.tRFM1  = t.tRFC1;
    t.tRFM2  = t.tRFC2;
    t.tRFMsb = t.tRFCsb;

    // 4.13.3: the interval between two REFab may be stretched to 5 x tREFI1 in
    // normal mode and 9 x tREFI2 in FGR. Selected against MR4 OP[4] by the
    // caller; the normal-mode figure is the default carried here.
    t.refi_stretch = 5;

    // Mode register and power-state timings. Where JESD79-5 gives max(nCK, ns)
    // the max is resolved here against this bin's tCK.
    t.tMRW   = max2(16, ceil_ck(10.0,  t.tCK_ns));
    t.tMRR   = max2(16, ceil_ck(10.0,  t.tCK_ns));
    t.tMRD   = max2(16, ceil_ck(10.0,  t.tCK_ns));
    t.tZQCAL = ceil_ck(1000.0, t.tCK_ns);
    t.tZQLAT = max2(8,  ceil_ck(30.0,  t.tCK_ns));
    t.tXP    = max2(8,  ceil_ck(7.5,   t.tCK_ns));
    t.tXS    = t.tRFC1 + ceil_ck(7.5,  t.tCK_ns);
    t.tCPDED = 4;
    t.tCKSRE = max2(8,  ceil_ck(10.0,  t.tCK_ns));
    t.tCKSRX = max2(8,  ceil_ck(10.0,  t.tCK_ns));

    // Initialisation, Table 11. tINIT3 is 4 ms and tINIT4 is 2 us of real
    // silicon time; at 0.4167 ns that is ~9.6 million and ~4800 cycles. The
    // device model scales them for simulation unless asked not to -- see
    // ddr5_device's INIT_FAST parameter.
    t.tINIT3 = ceil_ck(4_000_000.0, t.tCK_ns);   // 4 ms
    t.tINIT4 = ceil_ck(2_000.0,     t.tCK_ns);   // 2 us
    t.tINIT5 = 3;                                // 3 nCK of NOP
    t.tXPR   = t.tXS;                            // tXPR min = tXS

    // ECS operation time, Table 357: max(176 nCK, 110 ns).
    t.tECSc  = max2(176, ceil_ck(110.0, t.tCK_ns));

    return t;
  endfunction

endpackage : ddr5_timing_pkg
