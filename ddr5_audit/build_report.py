"""Build the self-contained Korean HTML report and machine-readable evidence."""
from pathlib import Path
import json,base64,hashlib,csv,zipfile,collections,datetime,argparse
ROOT=Path(__file__).resolve().parent
OUT=ROOT/'deliverables';OUT.mkdir(exist_ok=True)
D=json.loads((ROOT/'audited.json').read_text())
parser=argparse.ArgumentParser();parser.add_argument('--pdf',type=Path);parser.add_argument('--zip',type=Path)
args=parser.parse_args()
PDF=args.pdf or next(Path('/workspace/attachments').glob('*/JESD79-5B_v1-2.pdf'))
ZIP=args.zip or next(Path('/workspace/attachments').glob('*/rmc-ddr5-main.zip'))
SRC=ROOT/'source/rmc-ddr5-main/verif/ddr5_model'
hashof=lambda b:hashlib.sha256(b).hexdigest()
sources={}
with zipfile.ZipFile(ZIP) as z:
 for name in ['ddr5_device.sv','ddr5_pkg.sv','ddr5_timing_pkg.sv','ddr5_ecc_pkg.sv']:
  p=SRC/'rtl'/name;b=p.read_bytes();member='rmc-ddr5-main/verif/ddr5_model/rtl/'+name
  assert z.read(member)==b,'Supplied source changed'
  sources[name]={'text':b.decode(),'sha256':hashof(b),'lines':len(b.decode().splitlines()),'zip_member':member}
sources['tb_audit.sv']={'text':(ROOT/'tb_audit.sv').read_text(),'sha256':hashof((ROOT/'tb_audit.sv').read_bytes()),'lines':len((ROOT/'tb_audit.sv').read_text().splitlines()),'zip_member':'audit-created / independent white-box tests'}
for id,f in D['features'].items():
 for r in f['refs']:assert r['file'] in sources and 1<=r['start']<=r['end']<=sources[r['file']]['lines'],(id,r)
assert len({u['id'] for u in D['units']})==len(D['units'])
assert all(u['reason'] and u['status'] in 'FPNXUSE' for u in D['units'])
assert all(e in D['features'] for u in D['units'] for e in u['evidence'])
regression=json.loads((ROOT/'validation/results.json').read_text())
auditlog=(ROOT/'validation/audit_run.log').read_text()
independent=[]
for line in auditlog.splitlines():
 if line.startswith('AUDIT|'):
  _,id,status,detail=line.split('|',3);independent.append(dict(id=id,status=status,detail=detail))
assert len(independent)==14 and all(x['status']=='SPEC_FAIL' for x in independent)
D['sources']=sources
D['tests']={'regression':regression,'independent':independent,'audit_log':auditlog,'x4_log':(ROOT/'validation/x4_lint.log').read_text(),'crc':json.loads((ROOT/'validation/crc_equations.json').read_text())}
D['meta']={'generated':'2026-10-21 UTC','document':'JESD79-5B_v1.20 · September 2022','pdf_name':PDF.name,'pdf_sha256':hashof(PDF.read_bytes()),'zip_name':ZIP.name,'zip_sha256':hashof(ZIP.read_bytes()),'target':'rmc-ddr5-main/verif/ddr5_model/rtl/ddr5_device.sv','scope':'device module and directly invoked ddr5_pkg, ddr5_timing_pkg, ddr5_ecc_pkg; no credit for other ZIP files','source_unchanged':True,'simulator':'pip verilator distribution 5.48.0; runtime reports Verilator 5.49 (wheel build). C++20; warnings nonfatal.','report_version':'1.0 / static-review working matrix'}
D['findings']=[
 {'title':'리셋 기본값 불일치','detail':'MR0=00h/RL22, MR10~12=00h, MR15=0. 규격 기본값 08h/RL26, 2Dh, 3과 다릅니다.','features':['DEFAULT'],'pages':[43,44],'tests':['RESET_MR0','RESET_VREF','RESET_MR15']},
 {'title':'MRW/MRR 접근 조건 누락','detail':'R/O인 MR58을 덮어쓸 수 있고, active bank가 있어도 MRW/MRR를 진단하지 않습니다.','features':['MRW','MRR'],'pages':[48,52,114],'tests':['MRW_READONLY','MRW_BANK_IDLE','MRR_BANK_IDLE']},
 {'title':'MRR 직렬 출력과 read CRC 누락','detail':'MR 8bit를 beat마다 그대로 출력합니다. 규격의 polarity marker, 직렬 OP 배치·홀수 DQ 반전 및 CRC BL18과 다릅니다.','features':['MRR','RDCRC'],'pages':[48,49,50,51],'tests':['MRR_MAPPING','MRR_READ_CRC']},
 {'title':'합법적인 연속 READ가 소실','detail':'단일 rd_pend/rd_data 구조로 다음 READ가 앞선 READ의 launch 시각과 데이터를 덮어씁니다.','features':['READ'],'pages':[172],'tests':['READ_PIPELINE']},
 {'title':'Auto-PRE와 반복 PRE 타이밍','detail':'RDA 시 tRAS lockout을 적용하지 않습니다. 이미 idle인 bank에 반복 PREab를 보내면 마지막 PRE 시각도 갱신되지 않습니다.','features':['AP','PRE'],'pages':[155,156],'tests':['AUTO_PRECHARGE_TRAS','REPEATED_PREAB']},
 {'title':'x16 byte mask 불일치','detail':'DM을 byte별로 처리하지 않습니다. DM enable=1, DM_n=10에서 AB34를 써야 하지만 기존 1234가 유지됩니다.','features':['DM'],'pages':[69,345],'tests':['BYTE_MASK']},
 {'title':'RFM과 주기적 REF를 혼동','detail':'RFM-required=0이면 REF로 실행해야 하나 반환합니다. RFM이 periodic REF 기준 시각을 갱신해 refresh deadline에도 영향을 줍니다.','features':['RFM_REF'],'pages':[337,338],'tests':['RFM_DISABLED_IS_REF','RFM_NOT_PERIODIC_REF']},
 {'title':'폭·burst·속도 구성의 제한','detail':'x4 elaboration 실패, BL32 경로 없음, MR0 BL mode 미적용. timing package는 DDR5-4800B와 toy bin만 제공합니다.','features':['GEOM','BURST','SPEED'],'pages':[39,40,61,153,423],'tests':[]},
 {'title':'Self-refresh 종료·training 세부 누락','detail':'CS_n LOW에서 self-refresh를 종료합니다. LFSR 상태 유지, continuous pattern, internal WL/WICA, 2N sampling 등도 빠져 있습니다.','features':['SR','LFSR_STATE','CONTINUOUS','WL','2N'],'pages':[190,238,252,308],'tests':[]},
 {'title':'ECS·오류 보고의 부분 구현','detail':'manual scrub은 있지만 자동 ECS가 없고 MR14 reset 유지, address reset, 오류 counter encoding/snapshot이 규격과 다릅니다.','features':['ECS','AUTOECS','ECENC'],'pages':[313,314,315,316,317],'tests':[]},
 {'title':'주요 선택 기능과 ODT 상태 미구현','detail':'PPR/MBIST, PASR, loopback, DFE/DCA 제어, DRFM/ARFM 및 ODT state/timing 경로가 없습니다. 선택 기능도 넓은 분모에 포함했습니다.','features':['PPR','MBIST','PASR','LOOP','DFE','DCA','DRFM','ARFM','ODT'],'pages':[286,292,296,324,325,339,347],'tests':[]},
 {'title':'CRC 수학식 자체는 일치','detail':'CRC-8의 8개 XOR 식과 source shift algorithm은 영벡터+64개 기저벡터 모두 일치합니다. DQ bit mapping·frame·latency 적합성은 별개입니다.','features':['CRCPOLY','CRCFRAME'],'pages':[318,319],'tests':[]},
]
# Full reproducible data, including excluded items, original page text and headings.
(OUT/'audit-data.json').write_text(json.dumps(D,ensure_ascii=False,separators=(',',':')))
with (OUT/'sentence-audit.csv').open('w',encoding='utf-8-sig',newline='') as f:
 cols=['id','chapter','section','page','printed_page','kind','status','scope','optional','text','reason','evidence','code_refs','method','quality_flags']
 w=csv.DictWriter(f,fieldnames=cols);w.writeheader()
 for u in D['units']:
  if u['kind']!='sentence':continue
  v={k:u.get(k,'') for k in cols};v['printed_page']=D['pages'][u['page']-1]['printed']
  v['evidence']='; '.join(u['evidence']);v['code_refs']='; '.join(sorted({f"{r['file']}:{r['start']}-{r['end']}" for e in u['evidence'] for r in D['features'][e]['refs']}));v['quality_flags']='; '.join(u['quality_flags']);w.writerow(v)
jsdata=json.dumps(D,ensure_ascii=False,separators=(',',':')).replace('<','\\u003c').replace('\u2028','\\u2028').replace('\u2029','\\u2029')
html=(ROOT/'report_template.html').read_text().replace('__AUDIT_DATA__',jsdata).replace('__PDF_BASE64__',base64.b64encode(PDF.read_bytes()).decode())
(OUT/'JESD79-5B_ddr5_sentence_audit.html').write_text(html)
print(json.dumps({'html_bytes':len(html.encode()),'units':len(D['units']),'counts':D['counts'],'source_unchanged':True},ensure_ascii=False))
