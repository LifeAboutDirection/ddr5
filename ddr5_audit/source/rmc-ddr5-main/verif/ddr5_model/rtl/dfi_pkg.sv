// ---------------------------------------------------------------------------
// dfi_pkg.sv — DFI 5.2 constants and the latency arithmetic the controller
// needs to place its data enables.
//
// Signal grouping matches rmc_theory/docs/sched_rebuild/01_dfi_exchange_fabric.md.
// Per-phase signals are carried as packed vectors: phase N of a W-bit field
// lives at [N*W +: W], which is the SystemVerilog spelling of `dfi_<sig>_pN`.
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

package dfi_pkg;

  // dfi_freq_ratio encodings (cfg_freq_ratio in the fabric CSR map)
  parameter logic [1:0] FREQ_1_1 = 2'b00;   // G = 1
  parameter logic [1:0] FREQ_1_2 = 2'b01;   // G = 2
  parameter logic [1:0] FREQ_1_4 = 2'b10;   // G = 4

  function automatic int gear_of(input logic [1:0] ratio);
    case (ratio)
      FREQ_1_1: return 1;
      FREQ_1_2: return 2;
      FREQ_1_4: return 4;
      default:  return 2;
    endcase
  endfunction

  // dfi_phyupd_type
  parameter logic [1:0] PHYUPD_TYPE0 = 2'b00;
  parameter logic [1:0] PHYUPD_TYPE1 = 2'b01;
  parameter logic [1:0] PHYUPD_TYPE2 = 2'b10;
  parameter logic [1:0] PHYUPD_TYPE3 = 2'b11;

  // dfi_error_info codes used by this PHY model
  parameter logic [3:0] ERR_NONE          = 4'h0;
  parameter logic [3:0] ERR_WR_UNDERRUN   = 4'h1;  // wrdata_en high, no data
  parameter logic [3:0] ERR_RD_NO_DATA    = 4'h2;  // capture window saw only Z
  parameter logic [3:0] ERR_MULTI_CS      = 4'h4;  // >1 rank selected in a phase
  // NOTE: there is deliberately no CA-parity error code. DDR4 had CA parity on
  // a PAR pin; JESD79-5 dropped it, and ALERT_n's only defined use in DDR5 is
  // signalling a write-CRC error. A cfg_ca_parity_en / err_ca_parity pair in a
  // controller CSR map is a DDR4 carry-over with nothing to drive it.

  // -------------------------------------------------------------------------
  // Latency placement.
  //
  // The PHY presents phase N of the DFI group sampled at dfi cycle D on the
  // DRAM pins at absolute tCK slot D*G + N. Every path -- CA, write data,
  // read capture -- uses that same one-dfi-cycle pipeline, so the controller's
  // job reduces to arithmetic on absolute tCK slots.
  //
  // For a CAS whose first CA phase sits at (cycle Dc, phase p), the write data
  // must reach DQ at slot (Dc*G + p + WL). Decomposing that back into a
  // (cycle, phase) pair gives:
  //
  //     abs = p + WL
  //     wrdata_en cycle  = Dc + abs / G        <- lat_cycles()
  //     wrdata_en phase  =      abs % G        <- lat_phase()
  //
  // Reads are identical with RL in place of WL. `t_phy_wrlat` / `t_phy_rdlat`
  // as the fabric CSR map spells them are the p=0 case, which is why the
  // fabric must also carry the phase term when WL % G or RL % G is nonzero.
  // -------------------------------------------------------------------------
  function automatic int lat_cycles(input int phase, input int lat, input int g);
    return (phase + lat) / g;
  endfunction

  function automatic int lat_phase(input int phase, input int lat, input int g);
    return (phase + lat) % g;
  endfunction

endpackage : dfi_pkg
