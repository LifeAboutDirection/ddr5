"""Explain the saved audit's reproducible decision machinery, not private reasoning logs.
Does not alter the v1 judgments or source RTL.
"""
from pathlib import Path
import json,copy,collections,base64,gzip,re,html,sys
import audit_rules as a
import review_pass2 as b
ROOT=Path(__file__).resolve().parent
OLD=json.loads((ROOT/'audited.json').read_text()); RAW=json.loads((ROOT/'extracted.json').read_text())
um={u['id']:u for u in RAW['units']};om={o['id']:o for o in RAW['outline']}
records=[]
for final in OLD['units']:
 if final['kind']!='sentence':continue
 u=copy.deepcopy(um[final['id']]);first=a.classify(u,om);u.update(first)
 base_match=None
 if first['method']=='statement-rule':
  for i,(sec,pat,st,reason,ev) in enumerate(a.RULES,1):
   if a.starts(u['section'],sec) and pat.search(u['text']):base_match=dict(index=i,section=sec,pattern=pat.pattern,status=st);break
 prior=copy.deepcopy(u);b.review(u);second={k:u[k] for k in ['status','method','scope','reason']}
 second_match=None
 if prior['status']=='U' and u['method']=='reviewed-statement':
  for i,(sec,pat,st,reason,ev) in enumerate(b.R,1):
   if a.starts(u['section'],sec) and pat.search(u['text']):second_match=dict(index=i,section=sec,pattern=pat.pattern,status=st);break
 changed=any(final[k]!=u[k] for k in ['status','scope','method','reason','kind'])
 records.append(dict(id=final['id'],chapter=final['chapter'],section=final['section'],page=final['page'],text=final['text'],status=final['status'],method=final['method'],reason=final['reason'],evidence=final['evidence'],first=first,base_match=base_match,second=second,second_match=second_match,second_eligible=prior['status']=='U',final_changed=changed))
assert len(records)==3507
trace=json.loads((ROOT/'validation/methodology-replay.json').read_text())
srcdir=ROOT/'source/rmc-ddr5-main/verif/ddr5_model/rtl'
sources={p.name:p.read_text() for p in [srcdir/'ddr5_device.sv',srcdir/'ddr5_pkg.sv',srcdir/'ddr5_timing_pkg.sv',srcdir/'ddr5_ecc_pkg.sv',ROOT/'audit_rules.py',ROOT/'review_pass2.py',ROOT/'finalize_audit.py',ROOT/'extract_standard.py',ROOT/'tb_audit.sv']}
D=dict(records=records,outline=OLD['outline'],features=OLD['features'],sources=sources,trace=trace,page48=OLD['pages'][47]['text'],counts=dict(collections.Counter(r['method'] for r in records)),base_rule_count=len(a.RULES),second_rule_count=len(b.R),errata=[dict(id='P235-004',old_status='P',problem='기존 근거의 “MR31 전에 CRC가 꺼져 있어야 한다는 조건을 검사하지 않는다”는 설명은 코드와 다르다.',correction='ddr5_device.sv 1220–1221행에 if (mr[MR50][0]) prot(...)가 존재한다. CRC-off 선행 조건의 진단 호출은 구현되어 있다. 이는 일반 MRR의 read-CRC 생성/BL18 구현과 다른 요구사항이다.',impact='기존 P를 정당화한 이 사유는 유효하지 않다. 이 설명서는 기존 v1 판정의 생성 경로를 기록하며 새로운 전체 점수는 산정하지 않는다. 해당 문장은 수정 검토 대상이다.')])
OUT=ROOT/'deliverables';OUT.mkdir(exist_ok=True)
(OUT/'DDR5_methodology_data.json').write_text(json.dumps(D,ensure_ascii=False,separators=(',',':')))
compressed=base64.b64encode(gzip.compress(json.dumps(D,ensure_ascii=False,separators=(',',':')).encode(),compresslevel=9,mtime=0)).decode()
template=(ROOT/'methodology_template.html').read_text()
def snip(name,start,end):
 lines=sources[name].splitlines();return '\n'.join(f'{i:4d}  {lines[i-1]}' for i in range(start,end+1))
replacements={'__GZIP__':compressed,'__RULE__':html.escape(snip('audit_rules.py',91,98)),'__APPLY__':html.escape(snip('audit_rules.py',225,227)),'__MRR_CODE__':html.escape(snip('ddr5_device.sv',1214,1245)),'__PIPE_CODE__':html.escape(snip('ddr5_device.sv',1562,1567)+'\n\n'+snip('ddr5_device.sv',1604,1612)),'__FINAL_RESULT__':html.escape(json.dumps(trace['first_pass'],ensure_ascii=False,indent=2)),'__REVIEW_GUARD__':html.escape(snip('review_pass2.py',235,236)),'__ERRATA_CODE__':html.escape(snip('ddr5_device.sv',1217,1222)),'__PAGE48__':html.escape(D['page48'])}
for key,val in replacements.items():template=template.replace(key,val)
(OUT/'DDR5_methodology_explained.html').write_text(template)
print(json.dumps({'html_bytes':len(template.encode()),'sentence_records':len(records),'rules':[len(a.RULES),len(b.R)],'methods':D['counts'],'trace_example':next(r for r in records if r['id']=='P048-010')},ensure_ascii=False))
