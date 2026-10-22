// ---------------------------------------------------------------------------
// dfi_if.sv — DFI 5.2 interface between the RMC exchange fabric and the PHY.
//
// Signal set follows rmc_theory/docs/sched_rebuild/01_dfi_exchange_fabric.md.
// Per-phase signals are packed: phase N of a W-bit field is [N*W +: W], the
// equivalent of DFI's `_pN` suffix. G is the gear ratio (1, 2 or 4).
// ---------------------------------------------------------------------------
`timescale 1ps/1fs

interface dfi_if #(
  parameter int G       = 2,     // gear ratio: dfi_clk : tCK
  parameter int DQ_BITS = 16,
  parameter int CA_W    = 14,
  parameter int N_CS    = 1      // ranks
) (
  input logic dfi_clk
);

  localparam int PH_DATA_W = 2 * DQ_BITS;          // one phase = one tCK = 2 UI
  localparam int PH_MASK_W = 2 * (DQ_BITS/8);

  // ---- command / address (control interface) ----
  logic [G*CA_W-1:0]     address;
  logic [G*N_CS-1:0]     cs;            // active HIGH, per DFI 5.x
  logic [G-1:0]          act_n;         // DDR4 legacy; unused for DDR5
  logic [G-1:0]          cke;
  logic [G-1:0]          odt;
  logic [G-1:0]          parity_in;
  logic                  reset_n;
  logic                  dram_clk_disable;

  // ---- write data interface ----
  logic [G-1:0]              wrdata_en;
  logic [G*PH_DATA_W-1:0]    wrdata;
  logic [G*PH_MASK_W-1:0]    wrdata_mask;
  logic [G*N_CS-1:0]         wrdata_cs;

  // ---- read data interface ----
  logic [G-1:0]              rddata_en;
  logic [G*PH_DATA_W-1:0]    rddata;
  logic [G-1:0]              rddata_valid;
  logic [G*N_CS-1:0]         rddata_cs;

  // ---- status interface ----
  logic                  init_start;
  logic                  init_complete;

  // ---- update interface ----
  logic                  ctrlupd_req, ctrlupd_ack;
  logic                  phyupd_req,  phyupd_ack;
  logic [1:0]            phyupd_type;
  logic                  phymstr_req, phymstr_ack;

  // ---- error interface ----
  logic                  error;
  logic [3:0]            error_info;

  modport ctrl (
    input  dfi_clk,
    output address, cs, act_n, cke, odt, parity_in, reset_n, dram_clk_disable,
    output wrdata_en, wrdata, wrdata_mask, wrdata_cs,
    output rddata_en,
    input  rddata, rddata_valid, rddata_cs,
    output init_start,
    input  init_complete,
    output ctrlupd_req, phyupd_ack, phymstr_ack,
    input  ctrlupd_ack, phyupd_req, phyupd_type, phymstr_req,
    input  error, error_info
  );

  modport phy (
    input  dfi_clk,
    input  address, cs, act_n, cke, odt, parity_in, reset_n, dram_clk_disable,
    input  wrdata_en, wrdata, wrdata_mask, wrdata_cs,
    input  rddata_en,
    output rddata, rddata_valid, rddata_cs,
    input  init_start,
    output init_complete,
    input  ctrlupd_req, phyupd_ack, phymstr_ack,
    output ctrlupd_ack, phyupd_req, phyupd_type, phymstr_req,
    output error, error_info
  );

endinterface : dfi_if
