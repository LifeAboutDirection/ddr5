`timescale 1ns/1ps
import rmc_pkg::*;

module rmc_top (
  // AXI clock domain
  input  logic axi_aclk,
  input  logic axi_aresetn,
  // MC clock domain
  input  logic mc_clk,
  input  logic mc_aresetn,
  // DFI 5.2 (external PHY) — stub width, expand at integration
  output logic dfi_cmd_valid,
  output logic [2:0] dfi_cmd,
  input  logic [DATA_WIDTH-1:0] dfi_rddata,
  input  logic dfi_rddata_valid,
  output logic [DATA_WIDTH-1:0] dfi_wrdata,
  input  logic dfi_alert_n
);

  // ---------------------------------------------------------------
  // CIF domain (axi_aclk)
  // ---------------------------------------------------------------
  rmc_axi_wr_port  u_axi_wr (/* TODO connect */);
  rmc_axi_rd_port  u_axi_rd (/* TODO connect */);
  rmc_amu          u_amu    (/* TODO connect */);
  rmc_burst_splitter u_split (/* TODO connect */);
  rmc_rob          u_rob    (/* TODO connect */);
  rmc_merge_logic  u_merge_logic (/* TODO connect */);

  // CDC boundary — single async FIFO pair per locked decision
  rmc_async_req_fifo  u_req_fifo  (/* TODO connect */);
  rmc_async_resp_fifo u_resp_fifo (/* TODO connect */);

  // ---------------------------------------------------------------
  // MC core (mc_clk) — all intra-MC = valid-credit
  // ---------------------------------------------------------------
  rmc_gc_counter        u_gc        (/* TODO connect */);
  rmc_wdb                u_wdb      (/* TODO connect */);
  rmc_wr_tcam             u_wr_tcam (/* TODO connect */);
  rmc_rd_tcam             u_rd_tcam (/* TODO connect */);
  rmc_wr_status_reg       u_wr_status (/* TODO connect */);
  rmc_rd_status_reg       u_rd_status (/* TODO connect */);
  rmc_wr_watermark_mgr    u_wr_wm   (/* TODO connect */);
  rmc_rd_watermark_mgr    u_rd_wm   (/* TODO connect */);
  rmc_raw_bypass_mgr      u_raw     (/* TODO connect */);
  rmc_merge_unit          u_mrgunit (/* TODO connect */);
  rmc_hold_forward        u_holdfwd (/* TODO connect */);
  rmc_bank_activity_ctr   u_bactr   (/* TODO connect */);
  rmc_timing_reg_file     u_tregf   (/* TODO connect */);
  rmc_bank_partition_ctrl u_bpart   (/* TODO connect */);
  rmc_per_bank_fsm_table  u_bfsm    (/* TODO connect */);
  // TODO: rmc_per_rank_fsm_table, rmc_global_timing_table (not yet stubbed — add next)
  rmc_scheduler           u_sched   (/* TODO connect */);
  rmc_maintenance_engine  u_me      (/* TODO connect */);
  rmc_write_data_path     u_wdp     (/* TODO connect */);
  rmc_read_data_path      u_rdp     (/* TODO connect */);
  rmc_error_handler       u_errh    (/* TODO connect */);
  rmc_config_regs         u_csr     (/* TODO connect */);

endmodule : rmc_top
