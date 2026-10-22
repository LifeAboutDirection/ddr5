"""Traceable static audit rules. No positive status is inferred from a keyword
alone: F rules below cite inspected source behavior. Section fallbacks for mixed
features deliberately remain U (unresolved), never silently count as failures.
"""
import re

D='ddr5_device.sv'; P='ddr5_pkg.sv'; T='ddr5_timing_pkg.sv'; E='ddr5_ecc_pkg.sv'
FEATURES={}
def feature(key,title,status,reason,*refs):
    FEATURES[key]=dict(id=key,title=title,status=status,reason=reason,refs=[dict(file=f,start=a,end=b) for f,a,b in refs])

feature('PINS','핀 인터페이스','P','CK/CA/CS/RESET/DQ와 단일 DQS 쌍은 존재한다. x16의 독립 DQSL/DQSU, MIR, CA_ODT strap, TEN 및 LBDQ/LBDQS 핀이 없어 전체 핀 동작을 재현하지 못한다. CK_c는 입력 선언 외 동작에 사용하지 않는다.',(D,15,73),(D,333,341))
feature('GEOM','밀도·폭·주소','P','bank/row/column은 파라미터화했지만 DENSITY에서 주소 조직을 유도하지 않는다. 24Gb의 비이진 유효 행 제한, 3DS CID와 64Gb 타이밍이 없고, x4는 L1236/L1635에서 elaboration 오류가 재현된다.',(D,20,27),(D,57,73),(D,1021,1028),(D,1233,1236),(T,25,27))
feature('RESET','초기화·리셋','P','리셋 시 bank/MR/스케줄러를 초기화하고 INIT→NORMAL 상태를 둔다. 기본 INIT_FAST=1은 대기를 64CK로 단축한다. tINIT1/2 및 CS/CK 단계별 조건, 안정 전원 리셋 펄스폭, 초기 NOP 순서를 별도로 검증하지 않는다. MR0/MR10~12/MR15 기본값도 Table 9와 다르다.',(D,30,33),(D,346,439),(D,894,956),(D,1374,1393))
feature('DEFAULT','MR 리셋 기본값','X','MR 전체를 0으로 초기화한 뒤 일부만 덮어쓴다. Table 9의 MR0=08h(RL26), MR10~12=2Dh, MR15[2:0]=011b가 실제로는 00h/000b이다. 독립 검사 RESET_MR0/RESET_VREF/RESET_MR15에서 재현했다.',(D,359,360),(D,375,377),(D,407,421))
feature('MRW','MRW 및 접근 속성','P','MRW는 주소의 8bit를 그대로 저장한다. MR14[6] self-clear와 PDA 선택은 있지만 R/O/RFU 비트 마스크, 쓰기 가능 조건, all-banks-idle 검사가 없다. MR58에 대한 MRW가 실제 기능을 바꾸는 반례가 재현됐다.',(D,1196,1212),(D,1455,1459))
feature('MRR','MRR 데이터 매핑','X','정상 MRR은 레지스터 8bit를 모든 beat의 하위 8bit로 복제한다. 규격은 UI0~7의 polarity 표식과 UI8~15의 OP0~7 직렬 출력, 홀수 DQ 반전을 요구한다. all-banks-idle, per-bit MRR 선택과 read-CRC BL18도 구현되지 않았다.',(D,1214,1245),(D,1460,1463))
feature('CMD','명령 디코드','P','일반 1/2-cycle opcode를 decode_cmd1로 구분하지만 CA0=L이면 CA1과 무관하게 ACT로 처리한다. CID/NT-ODT/일부 조건부 CA 필드와 2N/geardown 샘플링이 없다. 지원 opcode 이름의 존재는 해당 기능의 구현 증거가 아니다.',(P,95,139),(D,1406,1538))
feature('CANCEL','2-cycle 취소','P','ACT/MRW/WRP는 두 번째 사이클 CS_n=0이면 실행하지 않는다. 그러나 규격상 합법적인 취소에도 prot() 오류를 더하며 tCMD_cancel 간격 검사가 없다.',(D,1414,1420),(D,254,267))
feature('BURST','BL·burst 순서','P','RD/WR 실행의 d.bl은 CA5만으로 8 또는 16을 고른다. cfg_BL을 계산하지만 사용하지 않아 MR0의 BL16/BC8/BL32/BL32-OTF 조합을 따르지 않는다. BC8 WRITE의 C3도 d.cstart=0으로 소실된다. MAX_BL=16이므로 BL32 데이터 경로가 없다.',(D,60,60),(D,110,126),(D,1431,1453),(P,335,350))
feature('PRE','PREpb/PREab/PREsb','P','세 종류 bank-close 동작과 기본 tRP/tRAS/tRTP/tWR 검사는 존재한다. PREab/PREsb는 이미 idle인 bank의 t_pre를 갱신하지 않아서 마지막 PRE 기준 tRP 조건에 불일치한다. Auto-PRE도 tRAS lockout을 포함하지 않는다.',(D,465,472),(D,515,522),(D,1083,1109),(D,1113,1142))
feature('AP','Auto precharge tRAS','X','RDA는 cur_ck+tRTP, WRA는 write end+tWR만으로 PRE 시각을 정한다. max(ACT+tRAS, ...)가 없어 합법적 READ 뒤에도 tRAS 전에 precharge된다. 독립 검사에서 요구 177CK에 대해 157CK가 재현됐다.',(D,1083,1087),(D,1106,1109))
feature('PREAMBLE','Preamble/Postamble','P','MR8에서 read/write preamble 길이는 읽지만 read DQS를 LOW로 유지할 뿐 지정 toggle 패턴은 생성하지 않는다. write 쪽은 DQS 구동 길이만 검사한다. postamble과 interamble 상태기계가 없다는 사실도 소스에 명시돼 있다.',(P,219,238),(D,1555,1592),(D,1595,1612))
feature('POST','Postamble·Interamble','N','MR8 postamble 비트와 READ/WRITE 간 gap에 따른 toggle/interamble 규칙을 실행하는 상태기계가 없다. 마지막 read beat 뒤에는 rd_driving을 내릴 뿐이다.',(D,1595,1612),(D,311,320))
feature('ACT','ACT·bank 타이밍','P','ACT의 bank/row 지정, open state, tRC/tRP/tRRD/tFAW 비교가 있다. 전체 주소 폭·밀도와 3DS, non-binary 행 주소를 포괄하지 않고 위반을 보고한 후에도 open_bank를 실행한다.',(D,465,487),(D,1021,1034),(D,1423,1429))
feature('READ','READ 경로·파이프라인','P','일반 READ에 RL 지연, burst ordering, ECC correction, DQS 출력이 있다. rd_pend와 rd_data가 단 하나여서 RL보다 짧은 합법적 READ 간격에서 앞선 READ가 덮어써진다. 독립 검사 CK100/112에서 첫 launch140이 152로 소실됐다.',(D,311,320),(D,1036,1089),(D,1558,1568),(D,1604,1612))
feature('WRITE','WRITE 경로','P','WL 뒤 DQS edge로 DQ를 저장하지만 wr_pend 하나를 다음 WRITE가 덮어쓴다. WR_partial, DM enable/byte mask, BC8 C3, tCCD_L_WR2 조건, 내부 RMW correction이 빠져 있다.',(D,1091,1111),(D,1431,1441),(D,1569,1586),(D,1621,1658))
feature('DM','Data Mask','X','DM_n의 모든 비트가 1일 때만 전체 DQ word를 쓴다. x16의 byte별 mask를 구현하지 않아 DM_n=10에서 써야 할 upper byte도 쓰지 않는다. MR5 DM enable 비트도 읽지 않는다. 독립 검사에서 기대 AB34 대신 1234가 유지됐다.',(D,52,52),(D,1633,1640))
feature('SR','Self refresh','P','SRE/SREF 상태 진입과 CS_n으로 exit, 일부 tXS 검사는 있다. SREF frequency-change 분기, tCKSRX, tSR/ODT timing, 자동 ECS, PASR, 내부 refresh schedule은 없다.',(D,1012,1016),(D,1479,1487),(D,1513,1523),(T,172,176))
feature('PD','Power down','P','PDE/PDX 상태와 tCPDED/tXP 비교는 있다. PDE 진입 전에 READ/WRITE/REF/MRW가 끝났는지와 모든 power-down 타이밍을 확인하지 않는다. ODT 상태 제어도 없다.',(D,939,945),(D,1012,1016),(D,1524,1532))
feature('FREQ','주파수 변경','N','실행 중 CK 주기 측정·타이밍 재산정·DLL lock 상태가 없다. T=get_timing(...)은 initial에서 한 번 실행되며 SRE와 SREF도 같은 분기로 처리한다.',(D,75,76),(D,1513,1523),(D,1289,1293))
feature('MPSM','Maximum Power Saving Mode','N','MR2[3]/[5]를 소비하는 동작과 MPSM 상태가 없다. dev_state_e와 check_cmd_legal의 전체 상태 분기를 확인했다.',(P,321,324),(D,911,956),(D,110,129))
feature('PASR','Partial Array Self Refresh','N','MR60의 segment mask를 읽는 경로와 masked/unmasked segment별 refresh/ECS 처리가 없다. Self-refresh는 하나의 전역 상태 전환뿐이다.',(D,1513,1523),(D,653,703))
feature('REF','Refresh','P','REFab/REFsb와 FGR에 따른 tRFC 비교 및 일부 간격 검사가 있다. 평균 tREFI/refresh credit, tREFSBRD/tREFSBRF/tRREFD, 온도·CA8 indicator, mode 전환 조건이 없다. check_refi는 첫 REF 전에는 검사하지 않고 REFsb도 반영하지 않는다.',(D,994,1008),(D,1144,1194),(T,94,103),(T,150,158))
feature('TEMP','온도 센서·refresh rate','N','온도 입력/모델과 MR4 온도 코드 갱신이 없다. cfg_fgr_mode=MR4[4]만 사용하며 MR4[2:0]/[3]의 동적 의미를 구현하지 않는다.',(D,110,129),(D,994,1008),(T,153,153))
feature('MPC','MPC','P','일부 MPC opcode는 실행하지만 DQS oscillator 등은 상수만 있고 default에서 아무 동작도 하지 않는다. MR2[4] multi-cycle 입력 안정·간격 검사는 없으며 PDA 선택도 MPC 전체에 적용되지 않는다.',(P,145,181),(D,1247,1359))
feature('PDA','Per DRAM Addressability','P','4bit enumerate/select ID 및 MRW 선택 gating은 있다. DQ0/DQS qualification, MR1 readback, 선택된 MPC/Vref gating, enumerate 내 허용 명령·1회 제한·tPDA timing이 없다.',(D,880,882),(D,1196,1202),(D,1271,1279),(D,1327,1338),(D,1533,1534))
feature('PATTERN','Read training pattern','P','MR31 special MRR에서 serial/LFSR/clock/invert/assignment를 생성한다. 매 호출마다 local LFSR을 MR26/27로 재시드해 이전 상태를 유지하지 않는다. serial도 MSB-first로 구현돼 원문의 bit mapping 대조가 필요하다. 연속 출력 모드와 tMRR_p=8CK 파이프라인은 없다.',(D,846,873),(D,1214,1231),(P,240,245))
feature('CONTINUOUS','Read continuous burst','N','MR25[3] 연속 출력 enable을 참조하지 않는다. 모든 MR31 요청은 16beat 후 종료되고 continuous mode exit 및 tCBME/tCont_Exit 상태가 없다.',(D,846,873),(D,1214,1231),(D,1604,1612))
feature('LFSR_STATE','LFSR state 유지','X','gen_read_training_pattern의 l0/l1은 automatic local 변수이며 매 MRR마다 MR26/MR27에서 다시 초기화된다. 마지막 상태를 보관하지 않으므로 연속 16회 MRR로 전체 LFSR 상태를 순회하라는 요구를 충족하지 못한다.',(D,846,865))
feature('RPRETRAIN','Read preamble training','N','MR2[0]를 소비하는 read preamble training 상태가 없다. in_training()도 CA/CS training과 MR2[1] write leveling만 확인한다.',(D,779,785),(D,1214,1245))
feature('CATM','CA training','P','CS_n-qualified CK sampling, CA XOR, 모든 DQ static feedback, 4CK 간격 및 2-cycle exit는 있다. tCATM_Valid/tCATM_Exit 지연, max8 및 NOP exit 조건·ODT를 포괄하지 못한다. exit와 같은 CK에 일반 decode가 재개되는 경로도 존재한다.',(D,793,814),(D,1315,1325),(D,1398,1410))
feature('CSTM','CS training','P','4개 CS sample을 쌍별 계산하여 OR하는 feedback은 있다. entry/valid/exit latency, 전체 command 제한과 2N/1N별 timing을 처리하는 상태가 없다.',(D,788,791),(D,816,830),(D,1315,1325),(D,1351,1354))
feature('WL','Write leveling','P','MR2[1] enable과 DQS 상승에서 CK_t를 sample하는 간단한 feedback만 있다. DDR5의 WRITE-command 기반 Internal Write Leveling Pulse, MR3 WICA, MR7 half-cycle, MR2[7], byte별 DQS·feedback, tWLO 등의 지연이 없다.',(D,333,337),(D,779,785),(D,1663,1670))
feature('CT','Connectivity Test','N','TEN 핀, CT mode 상태 및 CT XOR/feedback mapping이 없다. 모듈 포트와 모든 상태/command dispatch에서 해당 경로를 확인할 수 없다.',(D,43,54),(P,321,324),(D,1508,1538))
feature('ZQ','ZQ calibration protocol','P','ZQ START/LATCH와 tZQCAL/tZQLAT window, DES 제한은 구현했다. rank 공유 RZQ 순서와 모든 진입/종료 command spacing, 실제 저항 보정은 없다. 디지털 절차와 아날로그 저항 정확도는 별도 판정한다.',(D,911,919),(D,1295,1313),(D,1381,1393),(T,170,171))
feature('VREF','VrefCA/VrefCS shadow/apply','P','CA[11:5] 값을 shadow에 저장하고 MPC_APPLY에서 MR11/MR12에 반영한다. PDA/Group A/B 선택, multi-cycle timing과 settle 지연·유효 code 검사가 없다. RTT_CS shadow는 apply할 때 MR32[5:3]에 반영되지 않는다.',(D,1264,1270),(D,1330,1339),(D,1533,1534))
feature('VREFDQ','VrefDQ 제어','N','MR10 및 per-bit VrefDQ를 위한 효과·update/settle timer가 없다. 일반 mr[] byte 저장은 있지만 제어 의미를 실행하지 않으며 reset code도 규격과 다르다.',(D,359,360),(D,110,129),(D,1196,1212))
feature('PPR','Post Package Repair','N','MR23/MR24 guard-key sequence, spare row mapping, hPPR/sPPR 상태·tPGM 및 자원 readback 동작이 없다. 일반 메모리는 bank/row/col을 곧바로 key로 사용한다.',(D,89,99),(D,1196,1212),(D,1508,1538))
feature('MBIST','MBIST/mPPR','N','MR23 MBIST enable, guard keys, self-test FSM, tSELFTEST 완료 ALERT, MR22 result update가 없다. ALERT_n은 write CRC 경로에서만 LOW로 바뀐다.',(D,739,761),(D,1196,1212),(D,1395,1396))
feature('DFE','DFE/CTLE 디지털 제어','N','MR의 raw byte 저장만 있고 DFE gain/tap/enable 및 adaptation 상태·tDFE update timer가 없다. 전압·eye 개선 자체는 아날로그 제외 대상이나 MR 접근 속성과 update 절차는 디지털 미구현이다.',(D,110,129),(D,1196,1245),(P,187,217))
feature('OSC','DQS interval oscillator','N','START/STOP_DQS_OSC 상수는 선언됐으나 do_mpc case에 실행 분기가 없다. MR45 run time, MR46/47 count와 read mapping을 갱신하는 oscillator/counter가 없다.',(P,151,152),(D,1285,1357))
feature('2N','2N command sampling','N','cfg_2n_mode는 MR2에서 읽고 MPC도 해당 bit를 바꾸지만 CA capture 경로에서 한 번도 사용하지 않는다. 항상 연속 CK 두 개로 2-cycle 명령을 완료한다.',(D,123,123),(D,1285,1287),(D,1406,1465))
feature('WRP','Write Pattern','X','CMD_WRP를 CMD_WR와 같은 분기로 보내 DQS/DQ 외부 WRITE를 예약한다. MR48 pattern을 읽어 array에 쓰는 동작은 없다. WRP opcode 검출만으로 write pattern 기능을 구현했다고 볼 수 없다.',(D,1431,1441),(D,1091,1111),(D,1621,1647))
feature('ECC','On-die SEC ECC','P','x8/x16은 128data+8check SEC, read correction, ECS writeback이 있다. x4는 64bit+64bit 추가 fetch 대신 64bit를 zero-pad한다. 부분 WRITE/RMW에서 기존 오류를 고친 후 merge하지 않으며 writeback suppression도 없다.',(D,62,73),(D,551,601),(D,1036,1073),(D,1633,1647),(E,32,92))
feature('ECS','ECC transparency/ECS','P','manual scrub, counters, MR14 reset은 존재한다. 자동 ECS/자체 refresh scrub 및 전체 timing matrix가 없다. MR19/MR20은 규격의 threshold range 비트가 아닌 포화 binary count이고 Gb scaling·full-scan snapshot 시점도 다르다.',(D,628,703),(D,1203,1207),(D,1341,1349),(P,287,301))
feature('AUTOECS','Automatic ECS','N','ecs_step 호출은 MPC_MANUAL_ECS 안에만 있다. MR14[7]=0 또는 MR15[3]=1의 자동 scrub scheduler와 self-refresh oscillator 경로가 없다.',(D,1341,1349),(D,1371,1400),(D,1513,1523))
feature('ECENC','ECS count encoding','X','ecs_publish는 MR19=min(EpRC,63), MR20=min(EC,255)를 저장한다. 규격은 ETC×density×2^x 및 RETC×2^x 범위에 해당하는 비트를 설정하도록 한다. 결과 latch도 full array wrap 시점과 달리 매 오류 때 수행하고 wrap에서 MR들을 지운다.',(D,632,650),(D,670,700))
feature('CRCPOLY','CRC 다항식','F','crc8_d64는 초기 0, D[63]부터 shift, feedback polynomial 07h를 사용한다. 문서의 NewCRC[0..7] XOR 식과 zero+64개 기저 벡터를 비교해 65/65 일치했다. 이는 계산식의 증명이며 DQ mapping/timing의 증명은 아니다.',(E,94,107),(D,721,747))
feature('WRCRC','Write CRC','P','8bit CRC 비교·MR50[3] latch·ALERT 발생은 있다. x16도 x8처럼 nibble별 MR50[1:2]를 적용해 MR50[1] 하나로 전체 x16을 enable하는 규칙과 다르다. DQ bit mapping, BC8 fill, tCRC_ALERT와 pulse width도 별도 부족하다.',(D,717,761),(D,1395,1396),(D,1649,1658))
feature('CRCFRAME','CRC bit mapping/framing','X','crc_data_of_nibble는 UI당 DQ 순서로 D[63]부터 넣고 CRC도 역순으로 배치한다. 규격 표의 DQ/UI mapping을 그대로 구현한 것이 아니다. BC8 CRC를 nbeats+2=10UI에 받지만 규격은 항상 UI17/18이며 chopped 8UI는 1로 채워야 한다.',(D,721,736),(D,1649,1658))
feature('RDCRC','Read CRC','N','일반 READ/MRR에 read-CRC 생성·18/36UI 확장·read latency adder가 없다. MR50[0]은 MR31 사용 금지 검사에서만 읽는다.',(D,1036,1089),(D,1214,1245),(D,1604,1612))
feature('AUTOCRC','Write CRC auto-disable','N','MR50[4:5], MR51 threshold, MR52 window를 소비하는 오류/window counter가 없다. check_write_crc는 매번 동일하게 비교하고 ALERT를 발생시킨다.',(D,717,761),(D,1196,1212))
feature('LOOP','Loopback','N','LBDQ/LBDQS 핀·loopback mux와 MR53 routing이 없다. CATM/CSTM의 DQ feedback은 §4.39의 별도 loopback 기능과 다르다.',(D,43,54),(D,333,341),(D,110,129))
feature('STRAP','CA_ODT/MIR strap','N','CA_ODT/MIR 입력이나 reset strap sampling, Group A/B 분리·CA mirroring이 없다. group별 RTT MPC도 같은 shadow에 저장한다.',(D,43,54),(D,1266,1270))
feature('DCA','Duty Cycle Adjuster','N','MR42~44 및 per-bit DCA 설정을 출력 edge/상태에 적용하는 경로가 없다. DQS는 매 CK edge에서 단순 반전한다. 실제 analog duty distortion는 제외하되 code/update/readback 의미는 디지털 대상이다.',(D,110,129),(D,1604,1612),(D,1196,1245))
feature('RFM','Refresh management','P','per-bank RAA 증가·감소와 RAAMMT 진단, threshold decode는 있다. RFM_REQUIRED=0이면 REF로 취급하지 않고 return한다. RFM이 periodic REF와 t_ref_ab를 공유하여 REF deadline을 늦추며 모든 RFM/REF spacing도 포괄하지 않는다.',(D,958,1008),(D,1025,1027),(D,1144,1194),(P,260,279))
feature('RFM_REF','RFM not required일 때 REF','X','표준은 MR58[0]=0일 때 RFM을 REF로 실행하도록 요구한다. 구현은 RFMab/RFMsb에서 즉시 return하여 refresh timestamp와 RAA를 갱신하지 않는다. RFM_DISABLED_IS_REF 검사에서 재현됐다.',(D,1155,1158),(D,1179,1181))
feature('ARFM','Adaptive RFM','N','MR59[5:4] level A/B/C를 소비하지 않고 threshold를 MR58 및 MR59[7:6]로만 계산한다. level 전환 조건과 vendor thresholds/readback 갱신이 없다.',(D,124,129),(D,375,376),(P,260,279))
feature('DRFM','Directed RFM','N','per-bank sampled DRFM row register가 없고 CA5/CA9 DRFM flag와 MR59[0:3]를 처리하지 않는다. BRC, tDRFM, sampled-address clearing 및 RAA credit 예외도 없다.',(D,1113,1194),(D,1431,1453))
feature('OUTTEST','Package output driver test','N','MR61 test pattern enable을 사용하는 DQ driver 경로가 없다. DQ는 WL/CATM/CSTM/read 경로에서만 구동된다.',(D,333,341),(D,110,129))
feature('GEARDOWN','CS geardown','N','MR13 geardown bit, command capture ratio/phase와 입출구 동기화 동작이 없다. CA는 매 CK rising에서 처리된다.',(D,1251,1256),(D,1366,1372),(D,1473,1498))
feature('IO','IO 기능·모드','P','raw MR 저장과 기본 DQ/DQS 출력은 있으나 TDQS, DBI/feature-specific 설정 소비와 pin별 mode 전환을 확인할 수 없다. 문장의 실제 기능을 특정하지 못한 경우에는 판정을 보류한다.',(D,43,54),(D,110,129),(D,333,341))
feature('ODT','디지털 ODT 제어','N','저항값 일부를 MR/shadow에 저장하지만 RTT_WR/PARK/NOM 및 target/non-target ODT state/timer를 구현하지 않는다. DQ/DQS는 drive 또는 Z뿐이다. 저항 정확도는 아날로그 제외이며 enable/disable 상태·시간은 디지털 미구현이다.',(D,333,341),(D,1264,1270),(D,1333,1339))
feature('SPEED','Speed-bin 지원','P','JEDEC bin은 DDR5-4800B 하나와 비규격 toy bin뿐이다. 다른 속도 등급·CL 조합·3DS 값과 64Gb가 없다. 4800B도 고정 숫자이므로 각 조건/row별 완전 일치를 별도로 확인해야 한다.',(T,20,27),(T,94,103),(T,117,188))
feature('TIMING','전체 AC timing','P','핵심 명령 간 CK 비교만 존재한다. 표 전체의 speed/density/organization/CRC/2N/ODT/training 조건을 포괄하는 parameter 및 소비 경로는 없다. 선언만 있고 사용되지 않는 tCCD_L_WR2/tCKSRX도 있다.',(D,465,531),(D,1012,1016),(T,29,84),(T,106,188))
feature('ROUND','타이밍 반올림','P','ceil_ck는 ceil(ns/tCK−1e−9)이며 표준의 rounding correction/정수 ps 변환 알고리즘을 일반적으로 구현하지 않는다. 대부분 core timing도 상수이며 MR/주파수 변경에 재계산하지 않는다.',(T,86,92),(T,132,142))
feature('RAS','RAS·writeback suppression','P','SEC 코드와 오류 주입은 존재하지만 bounded-fault code mapping 검증, x4 RMW correction 및 MR9 writeback suppression 경로가 없다. 시스템 ECC controller의 책임은 이 DUT 범위 밖이다.',(E,48,65),(D,604,614),(D,583,601),(D,1633,1647))

SECTION_FEATURE={
 '2.6':'PINS','2.7':'GEOM','3.1':'CMD','3.2':'GEOM','3.3':'RESET','3.4.1':'MRR','3.4.2':'MRW','3.4.3':'DFE','3.4.4':'TIMING','3.5':'MRW',
 '4.1':'CMD','4.1.1':'CANCEL','4.2':'BURST','4.3':'PRE','4.4':'PREAMBLE','4.5':'POST','4.6':'ACT','4.6.1':'GEOM','4.7':'READ','4.8':'WRITE','4.9':'SR','4.10':'PD','4.11':'FREQ','4.12':'MPSM','4.13':'REF','4.14':'TEMP','4.15':'MPC','4.16':'PDA','4.17':'PATTERN','4.18':'RPRETRAIN','4.19':'CATM','4.20':'CSTM','4.21':'WL','4.22':'CT','4.23':'ZQ','4.24':'VREF','4.25':'VREF','4.26':'VREF','4.27':'VREF','4.28':'VREFDQ','4.29':'PPR','4.30':'MBIST','4.31':'DFE','4.32':'OSC','4.33':'TIMING','4.34':'2N','4.35':'WRP','4.36':'ECC','4.37':'ECS','4.38':'WRCRC','4.38.1':'WRCRC','4.38.2':'CRCFRAME','4.38.3':'CRCFRAME','4.38.4':'CRCFRAME','4.38.6':'AUTOCRC','4.38.7':'RDCRC','4.38.10':'CRCFRAME','4.38.11':'BURST','4.39':'LOOP','4.40':'STRAP','4.41':'DCA','4.42':'RFM','4.42.1':'ARFM','4.42.2':'DRFM','4.43':'OUTTEST','4.44':'GEARDOWN','4.45':'IO','5':'ODT','8.11':'CT','9.3':'LOOP','10':'SPEED','13.2':'ROUND','13.3':'TIMING','14':'TIMING','15':'RAS'
}

# Rules are semantic matches within inspected sections. No keyword-only F
# fallbacks. Exact sentences/clauses and narrow patterns get dedicated reasons.
RULES=[]
def rule(section,pattern,status,reason,*evidence):
    RULES.append((section,re.compile(pattern,re.I),status,reason,list(evidence)))

rule('3.4.1',r'operands.*select one of 256','F','MRA_BITS=8/N_MR=256와 c1_ca[5+:8]가 mr[] 주소를 선택한다. 이 판정은 주소 선택만을 평가하며 MRR wire encoding은 별도 불일치다.','MRR')
rule('3.4.1',r'MRR command is initiated','F','CS_n=0인 첫 CK에서 CMD_MRR를 decode하고 두 번째 CK에서 do_mrr를 호출한다. 일반 1N command-start 절차가 존재한다.','CMD')
rule('3.4.1',r'contents are available|odd DQ bit|Data in the burst \(BL0-7\)','X','UI0~7 polarity 및 UI8~15 bit 직렬/odd-DQ inversion이 없고 8bit 값을 beat마다 복제한다. MRR_MAPPING 반례와 일치한다.','MRR')
rule('3.4.1',r'all banks.*idle','X','do_mrr에는 bank_st 검사 loop가 없다. active bank 상태에서 MRR_BANK_IDLE 오류 수가 0인 반례를 재현했다. 3DS도 구현하지 않았다.','MRR','GEOM')
rule('3.4.1',r'DQS is toggled for the duration','P','일반 16beat MRR은 rd_driving 동안 DQS를 toggle한다. 그러나 read CRC가 켜진 18beat 요구까지 만족하지 않아 이 일반 문장을 완전 구현으로 계산하지 않는다.','MRR','RDCRC')
rule('3.4.1',r'command burst length 16 regardless','F','MR31 분기와 정상 분기 모두 nbeats=16이며 MR0 BL과 독립이다. CRC 확장은 다음 문장의 별도 미구현 항목이다.','MRR')
rule('3.4.1',r'CRC|BL18|17th|18th','N','MRR nbeats=16으로 고정되고 read CRC 생성/추가 DQS beat가 없다. MRR_READ_CRC 반례에서 기대18/실제16이다.','RDCRC')
rule('3.4.1',r'must not be interrupted','X','동일 rd_pend/rd_data를 후속 MRR/READ가 덮어쓸 수 있어 non-interruption을 보장하지 못한다.','READ','MRR')
rule('3.4.2',r'used to write configuration data','F','do_mrw가 선택된 mr[d.mra]에 d.op를 저장하고 refresh_mr_views를 호출한다. 이 문장의 일반 write 기능만 판정한다. 접근 속성은 별도 불일치다.','MRW')
rule('3.4.2',r'initiated with CS_n|address and the data.*contained in CA','F','first CA[12:5]에서 MRA, second CA[7:0]에서 OP를 취하고 CW=0일 때 do_mrw를 실행한다.','MRW','CMD')
rule('3.4.2',r'command period is defined by tMRW','F','do_mrw가 직전 t_mrw와 현재 cur_ck의 차이를 T.tMRW와 비교한다. speed별 tMRW 값 완전성은 13장의 별도 항목이다.','MRW')
rule('3.4.2',r'read-only registers have no impact','X','R/O mask 없이 mr[d.mra]=d.op 하므로 MR58/MR59 기능이 변한다. MRW_READONLY 재현 결과가 있다.','MRW')
rule('3.4.2',r'all banks.*idle','X','MRW에는 bank_st 전수 검사가 없다. active bank에서 쓰기를 허용하고 진단도 없어 MRW_BANK_IDLE 검사가 실패했다.','MRW')
rule('4.1',r'Bank group addresses.*determine','F','BG/BA를 추출하여 bank_of(bg,ba)=bg*N_BA+ba로 bank 배열을 선택한다. CID 및 밀도 예외는 별도 항목이다.','CMD','ACT')
rule('4.1',r'Precharge All command applies|Precharge Same Bank command applies|Precharge command applies to a single bank','F','do_precharge에서 PREab는 모든 active bank, PREsb는 각 BG의 동일 BA, PREpb는 지정 bank를 닫는다. 이 문장의 대상 선택 규칙을 구현한다.','PRE')
rule('4.1',r'SRE command places.*self refresh|PDE command places.*power down','F','CMD_SRE/SREF와 CMD_PDE dispatch가 각각 DS_SELF_REFRESH와 DS_POWER_DOWN을 설정한다.','SR','PD')
rule('4.1',r'If CW=Low.*MRW|If CW=HIGH.*ignores the MRW','F','MRW 두 번째 cycle에서 CA[10]==0일 때만 do_mrw를 호출하고 HIGH면 쓰지 않는다.','MRW')
rule('4.1',r'If CW=Low.*MRR|If CW=High.*MRR','F','MRR은 CW와 무관하게 do_mrr를 호출한다. CW=HIGH일 때 실행 여부가 허용 선택인 해당 문장을 충족한다.','MRR')
rule('4.1',r'DRAM does not execute.*CS.*LOW on 2nd|DRAMwill not execute.*CS_n is LOW|DRAM will not execute.*CS_n is LOW','P','실행 취소 자체는 구현됐으나 합법적인 cancel을 protocol error로 기록한다. timing 제한도 없으므로 완전 구현으로 세지 않는다.','CANCEL')
rule('4.2',r'currently limited to only sequential','F','burst_offset_rd/wr는 SEQ 순서만 생성하며 interleaved 선택 경로가 없다.','BURST')
rule('4.2',r'burst length.*defined by bits|options include|optional.*BL32|BL32.*optional','X','cfg_BL은 소비되지 않고 CA5만으로 8/16을 결정한다. MAX_BL=16이어서 선택 BL32도 불가능하다.','BURST')
rule('4.3',r'used to deactivate the open row','F','do_precharge가 지정 bank들의 bank_st를 IDLE, open_row를 -1로 바꾼다.','PRE')
rule('4.3',r'Once a bank has been precharged','F','close_bank가 IDLE로 바꾸고 check_cas가 ACTIVE가 아닌 bank의 RD/WR를 protocol error로 진단한다.','PRE','READ')
rule('4.3',r'CA10.*LOW.*auto-precharge','F','RD/WR second-cycle CA[10]==0을 d.ap로 만들고 auto-precharge 분기를 수행한다. 실행 시점 정확도는 별도 불일치다.','AP')
rule('4.3',r'RAS lockout|tRAS satisfied','X','RDA/WRA 내부 PRE 시각 계산에 ACT+tRAS와의 max가 없다. AUTO_PRECHARGE_TRAS로 실패를 재현했다.','AP')
rule('4.3',r'period shall be determined by the last PRECHARGE','X','PREab/PREsb에서 idle bank를 건너뛰어 최근 명령 시각이 반영되지 않는다. REPEATED_PREAB에서 기대100/실제20을 확인했다.','PRE')
rule('4.3',r'three different types of precharge','F','CMD_PREpb/CMD_PREab/CMD_PREsb가 선언되고 세 개 모두 do_precharge에서 실행된다.','PRE')
rule('4.6',r'ACTIVATE command is used to open','F','do_act가 decode된 bank/row로 open_bank를 실행한다.','ACT')
rule('4.6',r'value on the BG.*select.*bank','P','BG/BA/row 추출은 구현됐으나 x4 elaboration 및 24/64Gb 전체 조직을 만족하지 않는다.','ACT','GEOM')
rule('4.6',r'This row remains active','F','open_bank가 ACTIVE/open_row를 유지하며 PRE 및 auto-PRE에서 close_bank한다. 일반 정상 command sequence에서 해당 상태 유지가 구현된다.','ACT','PRE')
rule('4.6',r'bank must be precharged before opening','F','check_act가 bank_st!=BS_IDLE이면 prot로 진단한다. verification model이므로 불법 입력 후 데이터값까지 규정된 것으로 간주하지 않는다.','ACT')
rule('4.6',r'tRRD_S.*used|tRRD_L.*used|two different timing parameters|maximum of four.*tFAW','F','ACT 경로가 t_act_bg/t_act_any로 tRRD_L/S를 검사하며 마지막 4개 ACT의 rolling tFAW window에 5번째가 들어오는지 검사한다.','ACT')
rule('4.6.1',r'.*','X','row>=2^ROW_BITS만 검사하고 24Gb MSB/MSB−1 조건을 구현하지 않는다. 유효하지 않은 non-binary 주소에도 normal READ/WRITE가 실행된다.','GEOM')
rule('4.13',r'average periodic interval|average refresh interval|pulled.in|postpon|pull.in|credit|tREFSBRD|tREFSBRF|tRREFD','P','REF command와 max gap 일부만 검사한다. 평균 간격/refresh credit 및 REFsb 교차 명령 간격을 위한 상태·검사는 없다.','REF')
rule('4.16',r'Enumerate ID is a 4-bit field','F','pda_enum_id와 pda_sel_id를 logic[3:0]으로 선언하고 해당 MPC low4bit를 저장한다.','PDA')
rule('4.16',r'PDA applies to|PDA.*applies to MRW|same as the PDA Enumerate ID.*apply','P','MRW에는 ID gating이 있지만 do_mpc/Vref dispatch는 pda_selected를 호출하지 않아 문장에 나열된 모든 명령에 적용되지 않는다.','PDA')
rule('4.16',r'DQ0|DQL0|receive FIFO|strobe edge|captur.*DQ','N','PDA enumerate에서 DQ/DQS를 샘플링하는 FIFO/qualification이 없다. pda_enum_mode이면 d.op[3:0]을 바로 ID에 저장한다.','PDA')
rule('4.17',r'continuous|tCont_|tCBME','N','MR25[3]를 읽는 경로가 없고 모든 training pattern은 16beat로 끝난다. continuous 진입/출력/종료를 구현하지 않았다.','CONTINUOUS')
rule('4.17',r'retain its previous state|full state space.*16 MRR|state of the LFSR.*not change|state of both LFSR|actively computing next states','X','l0/l1이 매 MR31 호출마다 재시드되며 상태가 persistent하지 않다. clock pattern 설정에서도 local LFSR advance를 수행한다.','LFSR_STATE')
rule('4.17',r'default value.*(?:0x5A|0x3C|0xFE|0x00|0x0)|register settings default to 0|setting default is 0xFE','F','do_reset에서 MR25=0, MR26=5Ah, MR27=3Ch, MR28/29=00h, MR30=FEh로 초기화한다. 명시된 training default와 일치한다.','PATTERN')
rule('4.17',r'returned data will be a pattern|pattern is accessed when.*MR31','F','do_mrr가 MR31을 따로 처리하여 gen_read_training_pattern을 호출하고 read CRC enable이면 prot로 진단한다.','PATTERN')
rule('4.17',r'LFSR is an 8-bit Galois|polynomial for the Galois|two instances of the same LFSR polynomial','F','8bit l0/l1 두 상태에 Galois next-state function을 적용한다. 0xB8 feedback은 x8+x6+x5+x4+1이다. 지속 상태 요구는 별도 불일치다.','PATTERN')
rule('4.17',r'value of 0.*leave the pattern un.inverted|value of 1.*invert the pattern|will additionally invert the pattern','F','rd_data[beat][d] = v ^ inv[d]이며 inv는 {MR29,MR28}이다. bit0은 유지, bit1은 반전한다.','PATTERN')
rule('4.17',r'first UI.*value of 0|second UI.*value of 1','F','clock pattern 선택 시 bit0/bit1=beat[0]이므로 UI0=0, UI1=1로 반복된다.','PATTERN')
rule('4.17',r'produce a constant 0 pattern|0x00.*not produce a pattern','F','zero seed는 lfsr8_next에서 계속 zero이며 MSB output도 0이다. 문장의 LFSR source 특성만 판정한다. inversion은 별도 MR 기능이다.','PATTERN')
rule('4.17',r'back to back|tMRR_p|every 8 tCK','X','MR31도 T.tMRR를 검사하고 rd_pend 하나를 재사용한다. 8CK마다 pattern MRR를 보낼 수 있는 queue 및 별도 tMRR_p 처리가 없다.','PATTERN','READ')
rule('4.19',r'sampled.*rising CK|Sampling of the CA signals ONLY|values are XOR|driven on all the DQ pins|held until the next sample','F','training_ck_edge에서 CS_n LOW의 첫 cycle에 ^CA를 train_val에 latch하고 DQ 전체에 복제해 다음 sample까지 유지한다.','CATM')
rule('4.19',r'maximum sampling rate.*4tCK|CS_n shall be asserted every 4tCK','F','fresh CS assertion마다 chk(tCATM_CS,last,4)를 호출해 4CK 미만 간격을 진단한다.','CATM')
rule('4.19',r'enabled through an MPC command','F','MPC_ENTER_CA_TRAIN dispatch가 DS_CA_TRAINING을 설정한다.','CATM')
rule('4.19',r'no functional commands|no other commands will be interpreted','P','DS_CA_TRAINING 동안 decode를 건너뛴다. 다만 exit를 인식한 같은 edge에 state가 복구된 뒤 일반 decode가 실행되어 exit NOP 조건까지 완전하게 보호하지 않는다.','CATM')
rule('4.21',r'program MR2:OP\[1\]=1|program MR2:OP\[1\]=0','F','wl_training_on이 MR2[1]을 직접 읽고 DQ feedback 우선순위를 활성/비활성화한다.','WL')
rule('4.21',r'WICA|MR3|MR7|Internal Write Leveling Pulse|Internal Write Timing|independently|separate feedback|upper diff|lower diff','N','단일 DQS에서 CK_t를 sample할 뿐 내부 WRITE pulse/WICA/MR7/MR2[7] 또는 x16 byte별 feedback을 구현하지 않는다.','WL')
rule('4.23',r'ZQCal Start.*ZQCal Latch|tZQCAL|tZQLAT','P','start/latch CK window와 DES 제한은 구현했다. 그러나 문장의 모든 entry prerequisite·rank sharing·CA timing까지 대조된 것은 아니므로 부분 범위로 기록한다.','ZQ')
rule('4.24',r'7.bit|OP\[6:0\]|CA\[11:5\]','P','CA[11:5]가 shadow_vrefca에 전달된다. PDA, multi-cycle/settle timing과 유효 code 제한이 없어 명령 전체의 준수는 아니다.','VREF')
rule('4.25',r'7.bit|OP\[6:0\]|CA\[11:5\]','P','CA[11:5]가 shadow_vrefcs에 전달된다. PDA, multi-cycle/settle timing과 유효 code 제한이 없어 명령 전체의 준수는 아니다.','VREF')
rule('4.36',r'For a x4|in a x4 device|x4 devices|additional section|two 64.bit sections','X','x4는 16×4=64bit만 gather하고 128bit 나머지를 zero-pad한다. 추가 64bit array fetch/RMW가 없으며 x4 elaboration 오류도 재현됐다.','ECC','GEOM')
rule('4.36',r'On reads.*corrects any single.bit','F','do_read가 lane별 ecc_correct_lane을 호출하고 corrected lane_w에서 burst를 생성한다. read-path single-bit correction은 기존 ECC regression에서도 실행됐다.','ECC')
rule('4.36',r'shall not write the corrected data back','F','do_read는 corrected local lane_w만 사용한다. mem/ecc_store에 correction을 쓰는 경로는 없고 ECS의 ecc_scatter와 구별된다.','ECC')
rule('4.36',r'On writes.*computes ECC','P','burst completion에서 ecc_update_block을 호출한다. full x8/x16은 처리하지만 x4·partial RMW에서는 기존 오류 correction과 merge가 부족하다.','ECC')
rule('4.36',r'correct any single.bit errors.*internal read','X','write capture가 mem을 직접 덮어쓴 뒤 raw ecc_gather로 check bits를 재계산한다. merge 전 ecc_correct_lane 호출이 없다.','ECC')
rule('4.36',r'128 data bits.*8 ECC|internal Single Error Correction','P','ECC_DATA_BITS=128/ECC_CHECK_BITS=8과 SEC logic은 구현했다. x4의 실제 128bit prefetch 구성은 빠져 있어 모든 organization에서 완전 구현은 아니다.','ECC')
rule('4.36',r'case of a x8 device, no extra prefetch|For a x16 device, two|Each 128 Data bits.*separately|code word is mapped to DQ','F','LANE_W=8, x8 1lane/x16 2lane으로 같은 external bank의 두 ECC key를 나누고 DQ lower/upper byte에 각각 corrected lane을 배치한다. 물리 bank 배치는 behavioral abstraction이다.','ECC')
rule('4.36.1',r'fully specified by the H matrix|Syndrome Decode block executes|ECC blocks show','F','build_h/ecc_check_bits/ecc_syndrome/ecc_locate와 correction이 존재한다. zero→-1, column match→bit index, unmatched→-2(DUE)로 동작한다.','ECC')
rule('4.37',r'automatic ECS|Automatic ECS|Self Refresh.*ECS','N','manual MPC 외에는 ecs_step을 호출하지 않는다. 자동 ECS와 self-refresh scrub schedule이 없다.','AUTOECS')
rule('4.37',r'EC\[|EC0|EC7|REC\[|REC0|REC5|within a range|corresponding bit|Density\(Gb\)|loaded into MR20|latched into MR16|retain the most recent|default MR15','X','MR19/20에 threshold-bin encoding이 아니라 raw saturating count를 기록하고 full-scan snapshot도 유지하지 않는다. MR15 default도 0으로 초기화된다.','ECENC','DEFAULT')
rule('4.37',r'row or code word error count.*tracked','P','MR14[5] 분기로 row/codeword 수를 누적하지만 MR20 encoding과 threshold/density scaling은 다르다.','ECS','ECENC')
rule('4.37',r'error counters.*reset each time.*bank group counter wraps','F','ecs_step이 마지막 bank에서 wrap하면 ecs_reset_counters를 호출한다. 보고용 MR까지 지우는 별도 오류는 다른 문장에 반영한다.','ECS')
rule('4.38.1',r'CRC polynomial used.*ATM','F','8bit feedback polynomial 07h와 initial zero/D63-first 구현이 표준의 8개 XOR식과 모든 64개 basis 및 zero에서 일치했다.','CRCPOLY')
rule('4.38.1',r'CRC for write and read|separate mode register bits','P','write CRC는 일부 구현됐지만 read CRC generator는 없다. 두 기능을 모두 요구하는 문장은 완전 구현이 아니다.','WRCRC','RDCRC')
rule('4.38.1',r'data mask.*cannot be enabled|data mask functions','N','CRC enable과 MR5 DM enable의 동시 설정 금지 검사나 mask disable 동작이 없다. write capture는 CRC와 무관하게 DM_n을 처리한다.','DM','WRCRC')
rule('4.38.5',r'enabled or disabled per each nibble.*x8|two separate write CRC enable.*x8|does not check CRC errors on the disabled nibble','F','check_write_crc가 MR50[1+nib%2]가 0인 nibble은 continue한다. x8의 두 nibble enable/disable만 평가한 판정이다.','WRCRC')
rule('4.38.5',r'x4 or x16|unused write CRC enable bit','X','x16도 nib%2로 MR50[2]를 소비한다. MR50[1] 하나로 x16 전체 CRC를 enable해야 하는 규칙과 다르다. x4는 compile도 실패한다.','WRCRC')
rule('4.38.5',r'DRAM can write data.*without waiting','F','DQ capture에서 mem에 먼저 쓰고 추가 CRC 2UI를 받은 후 check_write_crc를 호출한다. full write의 speculative write 허용을 구현한다.','WRCRC','WRITE')
rule('4.38.5',r'There is no write latency adder','F','wr_pend.launch_ck는 항상 cur_ck+cfg_WL이며 write CRC enable이 launch latency를 바꾸지 않는다.','WRITE','WRCRC')
rule('4.38.9',r'set Write CRC Error Status|remains.*until the host clears','F','CRC mismatch 시 MR50[3]=1로 latch하며 timeout에서는 ALERT만 복구한다. MRW를 통한 명시적 clear 경로가 있다. reset은 별도 예외다.','WRCRC','MRW')
rule('4.38.9',r'latency to ALERT|pulse width','X','mismatch 검출 즉시 ALERT_n=0이며 ALERT_PW_CK=8 고정이다. tCRC_ALERT 및 ns 최소/최대 pulse 제약을 구현하지 않았다.','WRCRC')
rule('4.42',r'MR58.*OP\[0\].*=.?0.*(?:treat|REF)|treat.*RFM.*REF|CA9 is only required','X','MR58[0]=0이면 REF로 실행해야 하지만 RFM handler가 즉시 return한다. 독립 반례로 확인했다.','RFM_REF')
rule('4.42',r'does not replace.*periodic REF|nor does.*internal refresh counters','X','RFMab가 t_ref_ab를 갱신하여 check_refi의 periodic REF deadline을 연장한다. RFM_NOT_PERIODIC_REF에서 timestamp 변경을 재현했다.','RFM')
rule('4.42',r'minimum RAA value of 0|no negative|decremented by the RAAIMT|Issuing an RFMab.*decrement|Issuing an RFMsb.*decrement','F','raa_decrement는 max(raa−amount,0)이고 RFMab는 all banks, RFMsb는 모든 BG의 선택 BA에 cfg_raaimt를 적용한다. 일반 RFM-required 모드의 감소 규칙을 평가한다.','RFM')
rule('4.42',r'No decrement.*Self Refresh|per bank count.*remain unchanged','F','SRE/exit dispatch는 RAA를 수정하지 않으므로 count를 보존한다.','RFM','SR')
rule('4.42',r'If the RAA counter reaches RAAMMT','F','do_act가 raa_blocks_act를 호출해 RAA>=cfg_raammt이면 protocol error를 기록한다. 불법 ACT를 진단하는 checker 동작이다.','RFM')

def starts(sec,prefix):return sec==prefix or sec.startswith(prefix+'.')

def feature_for(sec,title):
    hits=[p for p in SECTION_FEATURE if starts(sec,p)]
    f=SECTION_FEATURE[max(hits,key=len)] if hits else None
    if sec.startswith('3.5.'):
        m=re.search(r'\bMR(\d+)\b',title)
        if m:
            mr=int(m[1])
            groups={0:'BURST',1:'PDA',2:'WL',3:'WL',4:'REF',5:'IO',6:'TIMING',7:'WL',8:'PREAMBLE',9:'RAS',10:'VREFDQ',11:'VREF',12:'VREF',13:'GEARDOWN',14:'ECS',15:'ECS',16:'ECS',17:'ECS',18:'ECS',19:'ECENC',20:'ECENC',21:'DFE',22:'MBIST',23:'PPR',24:'PPR',25:'PATTERN',26:'PATTERN',27:'PATTERN',28:'PATTERN',29:'PATTERN',30:'PATTERN',31:'PATTERN',32:'ODT',33:'ODT',34:'ODT',35:'ODT',36:'LOOP',37:'ODT',38:'ODT',39:'ODT',40:'TIMING',42:'DCA',43:'DCA',44:'DCA',45:'OSC',46:'OSC',47:'OSC',48:'WRP',50:'WRCRC',51:'AUTOCRC',52:'AUTOCRC',53:'LOOP',54:'PPR',55:'PPR',56:'PPR',57:'PPR',58:'RFM',59:'DRFM',60:'PASR',61:'OUTTEST',63:'MRW'}
            f=groups.get(mr,'DFE' if mr>=103 else 'MRW')
    return f

ANALOG=re.compile(r'\b(?:voltage|voltages|mV|mA|Ohm|Ohms|impedance|resistance|slew rate|eye height|eye width|jitter|differential swing|capacitance|pF|VIX|VIH|VIL|VOH|VOL|BER|latch.up|electrostatic|power supply|supply ramp)\b',re.I)
DIGITAL=re.compile(r'\b(?:MR\d+|MRW|MRR|MPC|opcode|command|counter|register|mode|enable|disable|RESET_n|tINIT\d|DQ\d+|CK|DQS|ODT|sequence|timing)\b',re.I)
def classify(u,outline_map):
    text=u['text'];s=u['section'];ch=u['chapter'];kind=u['kind'];lo=text.lower()
    title=outline_map.get(s,{}).get('title','')
    def result(status,scope,reason,ev=(),method='scope',optional=False):
        return dict(status=status,scope=scope,reason=reason,evidence=list(ev),method=method,optional=optional)
    optional=bool(re.search(r'optional|optionally',text+' '+title,re.I))
    if ch in ['FRONT','CONTENTS','FORM','OTHER','1','16','17','18']:
        return result('E','informative','표지·목차·범위/용어·측정 방법·변경 이력 또는 서식이다. 현재 DUT의 디지털 동작 요구사항을 별도로 정의하지 않아 분모에서 제외한다.')
    if ch=='2' and not (starts(s,'2.6') or starts(s,'2.7')):
        return result('E','physical','패키지 외형·ball pitch/ball 위치에 관한 물리 규정이다. pin의 논리 동작은 §2.6에서 별도 평가하며 위치 자체는 digital SV DUT의 구현 대상에서 제외한다.')
    if ch in ['6','7','12'] or (ch=='8' and not starts(s,'8.11')) or (ch=='9' and not starts(s,'9.3')) or starts(s,'13.1'):
        return result('E','analog','이 영역은 전압/전류·온도 허용범위·jitter/eye·측정 부하·정전용량 등 아날로그 또는 물리 검증 조건이다. 순수 digital event SV 모델의 논리 기능 분모에서 제외한다. digital command timing은 4·5·10·13장에서 따로 평가한다.')
    if ch=='11':
        return result('E','test_fixture','IDD/IDDQ/IPP 전류 측정용 host stimulus와 측정 조건이다. 디지털 패턴을 testbench에서 생성할 수는 있으나 ddr5_device.sv 내부에 해당 stimulus generator를 구현해야 하는 요구가 아니므로 DUT 구현률에서 제외한다.')
    if re.match(r'^(?:NOTE\s*\d+\s+)?(?:See|Refer to)\b',text,re.I) or re.match(r'^(?:Table|Figure)\s+\d+\s+(?:shows|illustrates|summarizes|lists|is|defines|provides|depicts)\b',text,re.I):
        return result('E','informative','표/그림을 안내하는 참조·설명 문장이다. 참조 대상의 문장·표 행은 별도 항목으로 남겨 중복으로 요구사항 수를 늘리지 않는다.')
    if re.fullmatch(r'(?:NOTE\s*\d+\s+)?(?:[\w\W]*?\b)?(?:RFU|Reserved|TBD)[.\s]*',text,re.I) and len(text)<65:
        return result('E','reserved','RFU/Reserved/TBD 표식만으로 실행할 동작·수치가 정의되지 않은 항목이다. 쓰기 금지나 readback 규칙이 명시된 다른 문장은 제외하지 않는다.')
    if kind=='table' and re.fullmatch(r'[ |\w\[\]:/(),.—+%-]*',text) and len(text)<150 and re.search(r'Parameter.*Symbol|Function.*Register.*Operand|Symbol.*MIN.*MAX|Function.*Abbrevia|OP\[7\].*OP\[0\]|MR Address.*MR Name',text,re.I):
        return result('E','structure','표의 열 제목/bit 위치 표식이다. 값이나 동작을 담은 표 행은 개별 항목에서 평가한다.')
    if re.match(r'^(?:The )?(?:host|controller|memory controller|system)\b',text,re.I) and re.search(r'retry|data coherency|adjustable delay|can be made more intelligent|back up the transactions|responsible for opening|locks DQS|check for an error in received',text,re.I):
        return result('E','host','controller의 재시도·시스템 coherency·PHY delay 선택 책임이다. DRAM DUT의 직접 동작이 아니므로 제외한다. DUT가 관측·검사할 수 있는 command/타이밍 조건은 별도로 포함한다.')
    if ANALOG.search(text) and not DIGITAL.search(text):
        return result('E','analog','문장의 수량/조건은 전압·전류·저항·jitter·물리 신호 품질이다. MR code 저장/제어와 구별하여 아날로그 부분만 제외한다.')
    # Original CRC pseudocode is a structural/formula entry, not prose.
    if 'NewCRC[' in text:
        u['kind']='formula'
        return result('F','digital',FEATURES['CRCPOLY']['reason'],['CRCPOLY'],'equation-proof')
    # Read-only/RFU constraints apply even when the feature itself is absent.
    if s.startswith('3.5') and re.search(r'read.only|R/O|write.only|W/O',text,re.I):
        return result('X','digital','mr[]에 대한 generic MRW/MRR는 비트별 R/O/W/O 보호를 두지 않는다(MR14[6]만 예외). 이 행/문장의 접근 속성을 보장하지 못한다. feature 값 저장만으로 기능 구현으로 계산하지 않는다.',['MRW','MRR'],'access-rule',optional)
    if s.startswith('3.5') and re.search(r'RFU.*(?:zero|0|must|shall)|reserved.*(?:zero|must|shall)',text,re.I):
        return result('N','digital','MR write의 RFU mask/값 검사가 없으므로 이 문장의 reserved field 제약을 검사하거나 강제하지 않는다.',['MRW'],'access-rule',optional)
    # Cross-cutting missing mechanisms: apply only to a complete mention of the
    # feature, never use these rules to claim a whole mixed sentence is F.
    cross=[(r'\b3DS\b|\bCID\[','GEOM'),(r'\b(?:non.target|NT) ODT\b|\bODTL\w*','ODT'),(r'\b(?:interamble|postamble)\b','POST'),(r'\b(?:MBIST|mPPR)\b','MBIST'),(r'\b(?:hPPR|sPPR|PPR guard)\b','PPR'),(r'\b(?:MPSM|Maximum Power Saving)\b','MPSM'),(r'\b(?:DRFM|BRC)\b','DRFM'),(r'\bARFM\b','ARFM'),(r'\b(?:DQS Interval Oscillator|DQS Oscillator|MR46|MR47)\b','OSC'),(r'\bwriteback suppression\b','RAS')]
    # Specific inspected statements take precedence over broad missing-feature rules.
    for prefix,pat,status,reason,ev in RULES:
        if starts(s,prefix) and pat.search(text):
            return result(status,'digital',reason,ev,'statement-rule',optional)
    for pattern,f in cross:
        if re.search(pattern,text,re.I):
            st=FEATURES[f]['status']
            if f=='GEOM':st='N'
            if f=='RAS':st='N'
            return result(st,'digital',FEATURES[f]['reason'],[f],'missing-mechanism',optional)
    f=feature_for(s,title)
    if f:
        F=FEATURES[f]
        # An entire absent mechanism is strong negative evidence. A partly
        # implemented section does not justify classifying each sentence P.
        if F['status']=='N':
            return result('N','digital',F['reason'],[f],'absent-feature',optional)
        if f in ['WRP','CRCFRAME','ECENC']:
            return result('X','digital',F['reason'],[f],'contradiction-scope',optional)
        if ch=='10' and not (s=='10.5' or starts(s,'10.5')):
            return result('N','digital','이 speed-bin/3DS operating point를 선택하는 enum·timing table이 없다. 구현은 DDR5-4800B와 toy bin만 제공한다. 동작 가능 주파수를 임의 변경하는 것과 규격 bin 구현은 다르다.',['SPEED'],'absent-feature',optional)
        return result('U','digital','관련 경로는 존재하지만 이 문장/표 행에 명시된 모든 조건을 만족한다는 개별 근거는 확정하지 못했다. '+F['reason'],[f],'section-evidence',optional)
    return result('U','undetermined','추출된 문맥만으로 디지털 DUT 요구사항 여부 또는 대응 실행 경로를 확정하지 못했다. 원문 페이지의 인접 표·그림과 함께 추가 판정이 필요하다. 구현률을 높이기 위해 제외하지 않는다.',[],'unresolved',optional)
