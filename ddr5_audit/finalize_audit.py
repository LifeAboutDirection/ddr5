"""Reproduce the static matrix, including conservative final review corrections.
No changes are made to the supplied DUT or its packages.
"""
import json, re, hashlib, collections
from pathlib import Path
from audit_rules import classify, FEATURES
from review_pass2 import review

ROOT=Path(__file__).resolve().parent
d=json.loads((ROOT/'extracted.json').read_text())
om={x['id']:x for x in d['outline']}
for u in d['units']:
    u.update(classify(u,om)); review(u)
byid={u['id']:u for u in d['units']}
def setv(ids, status, reason, ev=(), scope='digital', kind=None):
    for id in ids.split():
        u=byid[id]
        u.update(status=status,reason=reason,evidence=list(ev),scope=scope,method='final-individual-review')
        if kind:u['kind']=kind

# Whole clauses cannot be scored as fully implemented on only one matching phrase.
setv('P235-004','P','MR31 전용 pattern 생성은 있다. 그러나 MR31 전에 CRC가 꺼져 있어야 한다는 조건을 검사하지 않으며 MR50[0] read CRC 자체도 없다. 문장의 두 조건 중 하나만 확인된다.',['PATTERN','RDCRC'])
setv('P215-012 P215-014','P','VrefCA/CS와 RTT shadow 저장·유지는 있지만 MPC Apply에서 shadow_rtt_cs가 MR32에 반영되지 않는다. 나열된 모든 값의 apply 동작을 충족하지 못한다.',['VREF','ODT'])
setv('P217-048','P','MR2[4] reset=0은 맞지만 그 값이 허용해야 할 multi-cycle CS assertion을 decode/샘플링에 적용하지 않는다.',['MPC','DEFAULT'])
setv('P249-003','N','4번째 sample 직후 train_val을 갱신한다. 명시된 tCSTM_Valid 지연 및 전용 timer가 없다. 4sample grouping이 있다는 것만으로 이 timing 문장을 구현했다고 볼 수 없다.',['CSTM'])
setv('P249-067','E','여러 DRAM의 내부 timing 편차로 sample window가 달라질 수 있음을 설명하는 그림 예시다. 물리 variation을 모델링하거나 특정 시작 차이를 강제하는 조건은 아니다.',scope='informative')
setv('P260-005','P','MR2[1]=0에서 training feedback은 해제되지만 선행 WL_ADJ_end offset 계산/적용이 없다. 문장 전체 절차의 일부만 있다.',['WL'])
setv('P264-014','P','ZQ LATCH command를 재수신할 수 있으나 calibration 결과·impedance 값의 상태를 모델링하지 않는다. 디지털 command 수용은 확인되고 실제 relatch 결과는 추상화되어 있다.',['ZQ'])
setv('P312-009','P','x8/x16 경로의 single-bit correction은 코드 및 기존 ECC 테스트로 확인됐다. x4는 elaboration 오류와 128bit prefetch 누락이 있어 모든 device에 대한 이 문장은 완전 구현으로 계산하지 않는다.',['ECC','GEOM'])
setv('P056-003','U','원문은 “up to 8 MRA’s”라고 쓰지만 인접 문맥은 8bit 주소·256 MR을 설명한다. 코드에는 8bit MRA/256×8bit MR이 있다. 문서 표현의 의미를 8개의 MR 또는 8개의 주소 비트로 단정하지 않고 판정을 보류한다.',['MRW'])

# Resolve remaining prose whose scope or counterexample is explicit.
setv('P044-108 P044-109','N','초기화 단계별 ODT valid/uncalibrated 상태와 CS receiver CMOS-mode 전이가 없다. 디지털 enable/state 모델로 표현할 수 있는 조건이므로 포함한다.',['ODT','RESET'])
setv('P047-020','E','전원 rail 간 200mV 전압 차 조건이다. 논리 event 모델로 전압 정확도를 검증할 수 없어 analog 범주로 분리한다.',scope='analog')
setv('P065-017 P066-006','N','WL internal alignment/WICA 설정을 실제 WL pulse·capture timing에 반영하는 경로가 없다. MR bit 저장만으로 해당 training 절차를 지원하지 못한다.',['WL'])
setv('P155-023 P165-014 P168-006 P180-002 P180-004 P180-005 P194-049 P235-002 P238-001 P238-003','E','명령 표·그림·후속 설명에 대한 안내 또는 예시이다. 구체적인 기능/타이밍 요구는 인접 문장과 표 항목에서 따로 판정한다.',scope='informative')
setv('P168-003','F','check_precharge가 READ→PRE tRTP를, check_act가 PRE→ACT tRP와 ACT→ACT tRC를 검사한다. 이 항목은 external PRE의 조건이며 auto-PRE의 tRAS 누락과는 별도다.',['PRE','ACT'])
setv('P169-001','U','표 41/42의 CK→DQS 세부 min/max·온도/part 조건이 혼재한다. 모델은 CK edge에 DQS를 이상적으로 출력하며 각 수치를 모두 대조한 검증이 없어 이 포괄 문장은 보류한다.',['READ','TIMING'])
setv('P173-024 P173-028','E','RBL/WBL 약어의 정의이다. 실제 burst length 선택/CRC 확장은 다른 문장에서 평가한다.',scope='definition')
setv('P179-017','X','two-cycle WRITE는 cur_ck를 첫 command cycle로 되돌려 do_write를 호출하고 launch_ck=cur_ck+cfg_WL로 계산한다. 이 문장의 “final cycle” 기준보다 한 CK 이른 기준을 사용한다.',['WRITE'])
setv('P190-024','P','self-refresh 상태에서 일반 명령을 gate하지만 내부 clock gating/refresh schedule은 없고 전류 절감은 추상화한다. digital state 전환만 확인된다.',['SR'])
setv('P190-032 P190-036','P','tXS 비교는 있지만 self-refresh exit 검출이 잘못됐고 tCKSRX/DLL lock에 따른 command별 exit 지연 분기를 모두 구현하지 않는다.',['SR'])
setv('P194-004','X','DS_POWER_DOWN도 posedge CK_t에서만 처리한다. 문서가 요구하는 every-edge sampling을 위한 negedge 명령/PDX 처리 경로가 없다.',['PD','CMD'])
setv('P195-017','P','PDE는 bank active/refresh 진행 여부와 무관하게 state를 바꾸지만 pending operation 완료·IDD 전환 시점의 상태 구분은 없다. 전류 수치 부분은 analog 범위다.',['PD'])
setv('P195-018','P','ceil 기반 cycle 변환만 있고 §13.2의 1ps floor 및 0.30% correction 알고리즘을 적용하지 않는다.',['ROUND'])
setv('P195-021 P195-024','N','non-target command/ODT와 BL32·read CRC·BC8의 padded RBL을 처리하는 power-down entry matrix가 없다.',['PD','BURST','ODT'])
setv('P200-011','F','do_refresh가 command에서 bank 집합을 정한 후 CA bus를 추가 참조하지 않는다. 명령이 capture된 이후 외부 address의 유지에는 의존하지 않는다.',['REF'])
setv('P200-012','F','do_refresh가 대상 bank를 BS_REFRESHING으로 두고 t_busy_until 경과 시 maintenance가 BS_IDLE로 전환한다. 이 문장은 all-bank REF 문맥이다.',['REF'])
setv('P235-020 P243-016','S','host가 여러 rank의 RTT_PARK/RTT_NOM_RD를 맞추는 설정 절차이다. digital system SV에서 구현 가능하지만 이 단일 DUT에는 rank 간 scheduler/설정 controller가 없다. 전체 digital 집계에는 포함하고 DUT 내부 집계에서는 분리한다.',['ODT'],scope='system')
setv('P236-008','F','serial mode에서 MR26/MR27의 16bit를 읽어 pattern을 구성한다. 이 문장은 pattern register의 사용만 평가한다. serial bit 순서의 표 적합성은 별도 평가다.',['PATTERN'])
setv('P236-019 P237-004 P238-015','E','“may be restored”는 해당 상태 전이에서 기본값으로 돌아갈 수 있다는 허용 규정이다. 반드시 reset해야 한다는 의무로 간주하지 않으며 실제 값/host 재설정은 인접 항목에서 평가한다.',scope='permission')
setv('P238-020','X','gen_read_training_pattern 내부의 automatic l0/l1은 매 MRR마다 MR26/27 seed에서 다시 시작한다. MRR 사이에 이전 LFSR 상태를 보존하고 필요한 만큼만 advance하는 상태기계가 없다.',['LFSR_STATE'])

# Explicit digital predicates accidentally hidden in mixed analog paragraphs.
setv('P043-027 P043-038','P','전압의 0.2×VDDQ 정확도는 analog이지만 RESET_n LOW 유지/초기화 상태는 digital 대상이다. reset gate는 있으나 power-ramp 완료와 tINIT 단계별 유지 조건을 관측하지 않는다.',['RESET'])
setv('P046-002','F','negedge RESET_n은 현재 device state와 관계없이 do_reset을 실행한다. 0.2×VDDQ 수치의 전기적 판단은 제외하고 LOW assertion의 디지털 동작을 평가한다.',['RESET'])
setv('P045-007','P','training 선택을 허용하고 MR 값을 저장하지만 이 문장이 함께 요구하는 WL 관련 값의 적용은 internal WL/WICA 구현 누락으로 불완전하다.',['WL','RESET'])
setv('P056-015','P','정의되지 않은 MR bit를 저장할 수는 있으나 configuration별 유효/RFU field mask가 없어 다른 구성용 field가 기능에 영향을 주지 않는다는 보장을 제공하지 않는다.',['MRW'])
setv('P264-001','P','ZQCal START/LATCH command와 일부 timer는 존재한다. calibration된 driver/CA termination state는 표현하지 않으며 PVT/impedance 정확도는 analog 범위로 제외한다.',['ZQ','ODT'])
setv('P264-006','P','tZQCAL/tZQLAT timer를 선언하고 검사한다. command 수용 조건과 다른 동작에 대한 전체 timing matrix는 불완전하다.',['ZQ'])
setv('P265-010','S','여러 rank가 공유하는 ZQ 저항의 calibration 중첩 금지는 digital system scheduler/checker에서 표현할 수 있다. 단일 device에는 다른 rank 관측 정보가 없다.',['ZQ'],scope='system')
setv('P348-019 P361-011','N','저항의 실제 ohm 값은 analog 범위지만 MR code→선택된 ODT 상태라는 digital 제어 의미도 포함한다. 이 모델에는 해당 termination state 출력/제어 경로가 없다.',['ODT'])

# Include system-level digital duties in the user's broad digital denominator.
for u in d['units']:
    t=u['text'];s=u['section']
    if u['status']=='E' and (u['scope']=='host' or (u['chapter']=='14' and 'shown in Table' not in t) or u['id'] in ['P486-020','P486-021','P486-022','P486-026','P252-007','P252-011','P255-009','P321-001','P321-010','P321-011','P475-012','P043-102','P046-119','P045-012','P044-102']):
        u.update(status='S',scope='system',method='digital-system-scope',reason='digital SV의 host/controller 또는 여러 rank·channel을 보는 system checker로 구현할 수 있다. 이 단일 ddr5_device와 직접 사용 package에는 해당 host/system 절차가 없다. 넓은 digital 구현률 분모에는 포함하고 device-local 분모에서는 분리한다.')
    if u['status']=='E' and u['chapter']=='11' and (s!='11.1' or re.search(r'commands?|pattern|clock cycles|addresses|bank|burst|loop',t,re.I)) and not re.search(r'measur.*(?:current|voltage)|mA|[0-9]\s*V\b',t,re.I):
        u.update(status='S',scope='system',method='digital-system-scope',reason='전류 측정 자체는 analog 범위이나 이 항목의 command/data pattern·test sequence는 digital testbench에서 생성할 수 있다. DUT 안에는 이 측정 stimulus generator가 없다. 전체 digital 집계에 별도 system 항목으로 포함한다.')
    if u['status']=='E' and s.startswith('8.3'):
        if re.search(r'tJIT|tERR|period|cycle.to.cycle|n.period|pulse|jitter',t,re.I):
            u.update(status='N',scope='digital_timing',evidence=['FREQ','TIMING'],method='temporal-scope-review',reason='이 항목의 CK edge 간 period/jitter 수치·관계는 event-time SV checker로 표현 가능하다. 모델은 입력 CK 주기 측정, period/jitter 누적, 허용치 검사를 하지 않는다. 실제 전압·BER의 silicon 측정은 별도 analog 범위다.')
    if u['status']=='E' and u['chapter']=='9' and re.search(r'Duty Cycle.*adjusted.*(?:Adjuster|feature)',t,re.I):
        u.update(status='N',scope='digital',evidence=['DCA'],method='temporal-scope-review',reason='실제 analog duty 품질은 제외해도 MR의 Global/Per Pin Duty Cycle Adjuster 설정 및 event-time edge 조절은 digital로 표현 가능하다. 이 모델은 해당 설정을 소비하지 않는다.')
    if u['status']=='E' and u['chapter']=='9' and re.search(r'Spread Spectrum Clocking.*disabled',t,re.I):
        u.update(status='S',scope='system',method='digital-system-scope',reason='테스트를 위한 host clock generator의 SSC disable 조건이다. digital testbench에서 설정 가능하지만 단일 DRAM DUT가 host clock generator를 제어하지 않는다.')
    # Captions and waveform strings are not English sentences.
    if u['kind']=='sentence' and (re.match(r'^(?:Figure|Table)\s+\d+\s*[—–]',t) or t in ['PDA Select ID Mode','CS used to trigger exit of PD','DRAM must be idle DRAM must be idle']):
        u.update(kind='fragment',status='E',scope='structure',evidence=[],reason='그림/표 제목 또는 waveform 라벨이다. 원문 참조용으로 보존하고 문장 분모에서는 제외한다.',method='visual-label')
    u['quality_flags']=[]
    if re.match(r'^(?:MIN is|max\b|min\b)',t):u['quality_flags'].append('parameter-split: 원문 인접 문구와 연결 확인 필요')
    if u['kind']=='sentence' and not re.search(r'[.!?):;]$',t):u['quality_flags'].append('boundary: 페이지/텍스트 블록에서 문장이 끊겼을 수 있음')
    if len(t)>1300:u['quality_flags'].append('long-block: 복수 문장/목록이 결합되었을 수 있음')

FEATURES['ECS']['reason'] += ' MR14[6]은 즉시 self-clear되어 host clear까지 유지하는 규칙과 다르며 ECS 주소 counters도 초기화하지 않는다.'
FEATURES['SR']['reason'] += ' exit를 CS_n LOW에서 실행해 규격의 exit sequence와 다르다.'
d['features']=FEATURES
d['counts']={k:dict(collections.Counter(u['status'] for u in d['units'] if u['kind']==k)) for k in ['sentence','table','fragment','formula']}
(ROOT/'audited.json').write_text(json.dumps(d,ensure_ascii=False,separators=(',',':')))
print(json.dumps(d['counts'],ensure_ascii=False,indent=2))
