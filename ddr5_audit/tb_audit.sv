// Independent white-box counterexamples. No production source is changed.
// EXPECTED failures are specification mismatches, not simulator failures.
`timescale 1ps/1ps
module tb_audit;
  import ddr5_pkg::*;
  import ddr5_timing_pkg::*;
  logic CK_t=0, CK_c=1, CS_n=1, RESET_n=0;
  logic [13:0] CA=0;
  wire [15:0] DQ;
  logic [15:0] host_dq=0;
  logic host_en=0, host_dqs=0;
  wire DQS_t,DQS_c,ALERT_n;
  logic [1:0] DM_n=2'b11;
  assign DQ=host_en?host_dq:16'bz;
  assign DQS_t=host_en?host_dqs:1'bz;
  assign DQS_c=host_en?~host_dqs:1'bz;
  ddr5_device #(.VERBOSE(0)) dut(.*);
  int failures=0, checks=0;
  task automatic verify(input string id,input bit ok,input string detail);
    checks++;
    if (!ok) failures++;
    $display("AUDIT|%s|%s|%s",id,ok?"SPEC_PASS":"SPEC_FAIL",detail);
  endtask
  task automatic fresh();
    dut.do_reset();
    dut.dev_st=DS_NORMAL;
    dut.cur_ck=100;
    dut.ck_cnt=100;
    dut.d=dut.d_clear();
  endtask
  initial begin
    #2; RESET_n=1; #2;
    fresh();
    verify("RESET_MR0",dut.mr[0]==8'h08,$sformatf("Table 9 default MR0=08h (RL26); actual=%02h RL=%0d",dut.mr[0],dut.cfg_RL));
    verify("RESET_MR15",dut.mr[15][2:0]==3,$sformatf("MR15 ETC default=3 (256/Gb); actual=%0d",dut.mr[15][2:0]));
    verify("RESET_VREF",dut.mr[10]==8'h2d && dut.mr[11]==8'h2d && dut.mr[12]==8'h2d,$sformatf("MR10/11/12 default=2Dh; actual=%02h/%02h/%02h",dut.mr[10],dut.mr[11],dut.mr[12]));
    dut.d.mra=58; dut.d.op=0;
    dut.do_mrw(dut.d);
    verify("MRW_READONLY",dut.mr[58]=={3'b100,4'b1001,1'b1},$sformatf("MR58 must ignore MRW; actual=%02h expected=93h",dut.mr[58]));
    fresh(); dut.open_bank(0,0); dut.d.mra=0; dut.d.op=8'h08;
    dut.do_mrw(dut.d);
    verify("MRW_BANK_IDLE",dut.err_count>0,$sformatf("MRW while bank0 active must be diagnosed; errors=%0d",dut.err_count));
    fresh(); dut.open_bank(0,0); dut.d.mra=0;
    dut.do_mrr(dut.d);
    verify("MRR_BANK_IDLE",dut.err_count>0,$sformatf("MRR while bank0 active must be diagnosed; errors=%0d",dut.err_count));
    fresh(); dut.mr[0]=8'h08;dut.d.mra=0;
    dut.do_mrr(dut.d);
    verify("MRR_MAPPING",dut.rd_data[0]==16'haaaa && dut.rd_data[8]==16'haaaa,$sformatf("Tables14-16: UI0 and OP0 UI8=AAAAh for MR0=08h; actual=%04h/%04h",dut.rd_data[0],dut.rd_data[8]));
    fresh(); dut.mr[50][0]=1;dut.d.mra=0;dut.do_mrr(dut.d);
    verify("MRR_READ_CRC",dut.rd_pend.nbeats==18,$sformatf("MRR with read CRC must use BL18; actual=%0d",dut.rd_pend.nbeats));
    fresh();dut.mr[58][0]=0;dut.refresh_mr_views();dut.t_ref_ab=NEVER_VALUE();
    dut.do_refresh(dut.d,CMD_RFMab);
    verify("RFM_DISABLED_IS_REF",dut.t_ref_ab==100,$sformatf("MR58[0]=0: RFM must execute REF; t_ref_ab=%0d",dut.t_ref_ab));
    fresh();dut.t_ref_ab=0;dut.cur_ck=2000;dut.do_refresh(dut.d,CMD_RFMab);
    verify("RFM_NOT_PERIODIC_REF",dut.t_ref_ab==0,$sformatf("RFM must not postpone periodic REF deadline; last REF changes to=%0d",dut.t_ref_ab));
    fresh();dut.mr[0]=8'h24;dut.refresh_mr_views();dut.open_bank(0,0);dut.t_act[0]=0;
    dut.d.bank=0;dut.d.bg=0;dut.d.bl=16;dut.d.col=0;dut.d.cstart=0;
    dut.do_read(dut.d);
    dut.cur_ck=112;dut.d.col=16;dut.do_read(dut.d);
    verify("READ_PIPELINE",dut.rd_pend.launch_ck==140,$sformatf("Legal READs CK100/112 RL40 must retain first launch140; single pending launch now=%0d",dut.rd_pend.launch_ck));
    fresh();dut.mr[0]=8'h24;dut.refresh_mr_views();dut.open_bank(0,0);dut.t_act[0]=100;dut.cur_ck=139;
    dut.d.bank=0;dut.d.bg=0;dut.d.bl=16;dut.d.ap=1;
    dut.do_read(dut.d);
    verify("AUTO_PRECHARGE_TRAS",dut.t_pre[0]>=177,$sformatf("RDA internal PRE must satisfy ACT100+tRAS77=177; actual=%0d",dut.t_pre[0]));
    fresh();dut.t_pre[0]=20;dut.cur_ck=100;
    dut.do_precharge(dut.d,CMD_PREab);
    verify("REPEATED_PREAB",dut.t_pre[0]==100,$sformatf("Last PRE determines tRP even for idle bank; t_pre[0]=%0d",dut.t_pre[0]));
    fresh();dut.mr[5][5]=1;dut.backdoor_write(0,0,0,16'h1234);
    dut.wr_pend.bank=0;dut.wr_pend.row=0;dut.wr_pend.col_base=0;
    dut.wr_pend.cstart=0;dut.wr_pend.nbeats=16;
    host_en=1;host_dq=16'habcd;DM_n=2'b10;host_dqs=0;
    #2;dut.wr_open=1;dut.wr_seq=1;host_dqs=1;#2;
    verify("BYTE_MASK",dut.backdoor_read(0,0,0)==16'hab34,$sformatf("DM_n=10: write upper byte, preserve lower; actual=%04h expected=AB34",dut.backdoor_read(0,0,0)));
    host_en=0;dut.wr_open=0;
    $display("AUDIT_SUMMARY|checks=%0d|spec_failures=%0d",checks,failures);
    $finish;
  end
  function automatic longint unsigned NEVER_VALUE();return 64'h8000000000000000;endfunction
endmodule
