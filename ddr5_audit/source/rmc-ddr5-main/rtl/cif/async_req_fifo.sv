`timescale 1ns/1ps
import rmc_pkg::*;

module rmc_async_req_fifo #(
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
  input  logic wr_clk,
  input  logic wr_rst_n,
  input  logic wr_valid,     // credit-based push
  input  logic wr_data,      // TODO: struct
  output logic wr_credit,
  input  logic rd_clk,
  input  logic rd_rst_n,
  output logic rd_valid,     // registered
  output logic rd_data,
  input  logic rd_credit_return
);

  // TODO: implement

endmodule : rmc_async_req_fifo
