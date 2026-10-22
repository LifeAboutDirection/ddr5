from pathlib import Path
import argparse, json
p=argparse.ArgumentParser()
p.add_argument('--file',type=Path,default=Path(__file__).parent/'DDR6_sentence_checklist.json')
p.add_argument('--section');p.add_argument('--text');p.add_argument('--id');p.add_argument('--full',action='store_true')
a=p.parse_args();d=json.loads(a.file.read_text(encoding='utf-8'))
for c in d['chapters']:
 for r in c['records']:
  if a.section and not (r['section_id']==a.section or r['section_id'].startswith(a.section+'.')):continue
  if a.text and a.text.lower() not in r['source']['original_text'].lower():continue
  if a.id and a.id!=r['id']:continue
  print(json.dumps(r,ensure_ascii=False,indent=2) if a.full else f"{r['id']}  section={r['section_id']}  PDF={r['source']['pdf_page']}  {r['source']['original_text']}")
