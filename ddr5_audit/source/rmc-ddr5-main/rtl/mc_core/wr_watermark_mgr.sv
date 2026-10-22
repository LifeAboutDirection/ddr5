`timescale 1ns/1ps
import rmc_pkg::*;

module rmc_wr_watermark_mgr #(
  parameter int GC_WIDTH     = rmc_pkg::GC_WIDTH,
  parameter int ADDR_WIDTH   = rmc_pkg::ADDR_WIDTH,
  parameter int AXI_ID_WIDTH = rmc_pkg::AXI_ID_WIDTH,
  parameter int DATA_WIDTH   = rmc_pkg::DATA_WIDTH,
  parameter int STRB_WIDTH   = rmc_pkg::STRB_WIDTH,
  parameter int CH_BITS      = rmc_pkg::CH_BITS,
  parameter int RANK_BITS    = rmc_pkg::RANK_BITS,
  parameter int BG_BITS      = rmc_pkg::BG_BITS,
  parameter int BANK_BITS    = rmc_pkg::BANK_BITS,
  parameter int ROW_BITS     = rmc_pkg::ROW_BITS,
  parameter int COL_BITS     = rmc_pkg::COL_BITS,
  parameter int N_RANKS      = rmc_pkg::N_RANKS,
  parameter int N_BG         = rmc_pkg::N_BG,
  parameter int N_BANKS      = rmc_pkg::N_BANKS,
  parameter int N_WR_ENTRIES = rmc_pkg::N_WR_ENTRIES,
  parameter int N_RD_ENTRIES = rmc_pkg::N_RD_ENTRIES,
  parameter int WR_BUF_DEPTH = rmc_pkg::WR_BUF_DEPTH,
  parameter int TIMING_WIDTH = rmc_pkg::TIMING_WIDTH,
  parameter int PARAM_ID_WIDTH = rmc_pkg::PARAM_ID_WIDTH
)(
  input  logic clk,
  input  logic rst_n,
  input  logic alloc_req,
  output logic alloc_gnt,
  output logic [$clog2(N_WR_ENTRIES)-1:0] alloc_idx,
  input  logic retire_valid,
  input  logic [$clog2(N_WR_ENTRIES)-1:0] retire_idx,
  output logic [$clog2(N_WR_ENTRIES):0]   wr_count   // for WR_HIGH_WM/LOW_WM
);

  // TODO: implement

endmodule : rmc_wr_watermark_mgr
