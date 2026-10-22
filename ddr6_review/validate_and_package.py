from pathlib import Path
import collections, hashlib, json, zipfile
import jsonschema

ROOT=Path(__file__).parent;OUT=ROOT/'deliverables';VAL=ROOT/'validation'
def load(p):return json.loads(p.read_text())
def write(p,obj):p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
data=load(OUT/'DDR6_sentence_checklist.json');ledger=load(OUT/'DDR6_source_ledger.json')
records=[r for c in data['chapters'] for r in c['records']];record_ids={r['id'] for r in records}
sections={s['id'] for c in data['chapters'] for s in c['sections']};line_ids={l['id'] for l in ledger['lines']};allunits=record_ids|{u['id'] for u in ledger['unselected_units']}
tables={t['id']:t for t in data['table_supplements']};headings={h['id'] for h in data['source_headings_and_captions']}
schema={
 '$schema':'https://json-schema.org/draft/2020-12/schema',
 'title':'DDR6 sentence implementation-review checklist',
 'type':'object',
 'required':['format_version','source','purpose_ko','assessment_policy','statistics','methodology','chapters','table_supplements','page_ledger'],
 'properties':{
  'format_version':{'const':'1.0.0'},
  'source':{'type':'object','required':['sha256','pdf_pages'],'properties':{'sha256':{'type':'string','pattern':'^[a-f0-9]{64}$'},'pdf_pages':{'type':'integer','minimum':1}}},
  'assessment_policy':{'type':'object','required':['current_status','implementation_rate'],'properties':{'current_status':{'const':'not_assessed_no_rtl'},'implementation_rate':{'type':'null'}}},
  'statistics':{'type':'object','required':['checklist_records','implementation_assessed_records','implementation_rate'],'properties':{'implementation_assessed_records':{'const':0},'implementation_rate':{'type':'null'}}},
  'chapters':{'type':'array','items':{'type':'object','required':['id','sections','records','record_count'],'properties':{'records':{'type':'array','items':{'$ref':'#/$defs/record'}}}}},
  'table_supplements':{'type':'array','items':{'type':'object','required':['id','rows','review_checks_ko'],'properties':{'rows':{'type':'array','items':{'type':'object','required':['id','cells','source_line_ids','status'],'properties':{'status':{'const':'not_assessed_no_rtl'}}}}}}},
  'page_ledger':{'type':'array','minItems':527,'maxItems':527}},
 '$defs':{
  'record':{'type':'object','required':['id','chapter_id','section_id','record_kind','source','draft','scope','parsed_candidates','checks','verification_plan','dependency_review','provenance','assessment'],
   'properties':{
    'id':{'type':'string','pattern':'^D6-P[0-9]{3}-[0-9]{4}$'},
    'record_kind':{'enum':['sentence_candidate','draft_notice','clause_fragment_candidate']},
    'source':{'type':'object','required':['pdf_page','original_text','source_line_ids'],'properties':{'pdf_page':{'type':'integer','minimum':1,'maximum':527},'original_text':{'type':'string','minLength':1},'source_line_ids':{'type':'array','minItems':1,'items':{'type':'string'}}}},
    'draft':{'type':'object','required':['style_runs','candidate_is_authoritative'],'properties':{'candidate_is_authoritative':{'const':False}}},
    'checks':{'type':'array','minItems':1,'items':{'type':'object','required':['id','method','check_ko']}},
    'verification_plan':{'type':'object','required':['status','baseline','boundary','combinations'],'properties':{'status':{'const':'proposed_not_executed'}}},
    'provenance':{'type':'object','required':['semantic_review_status','independent_per_sentence_inference_performed'],'properties':{'semantic_review_status':{'enum':['selected_source_reviewed_example','generated_requires_sentence_review']},'independent_per_sentence_inference_performed':{'const':False}}},
    'assessment':{'type':'object','required':['status','verdict','evidence'],'properties':{'status':{'const':'not_assessed_no_rtl'},'verdict':{'type':'null'}}}}}}
}
write(OUT/'DDR6_checklist.schema.json',schema)
jsonschema.Draft202012Validator.check_schema(schema)
jsonschema.Draft202012Validator(schema).validate(data)
assert len(record_ids)==len(records)
assert len(line_ids)==len(ledger['lines'])
assert len(data['page_ledger'])==527
assert data['statistics']['uncovered_line_ids']==[]
assert len(sections)==data['statistics']['section_count']
for c in data['chapters']:
    assert c['record_count']==len(c['records'])
    assert c['sentence_candidate_count']==sum(r['record_kind']=='sentence_candidate' for r in c['records'])
    assert set(c['table_ids'])<=tables.keys()
for r in records:
    assert r['section_id'] in sections or r['section_id']=='FRONT',r['id']
    assert set(r['source']['source_line_ids'])<=line_ids,r['id']
    assert len({c['id'] for c in r['checks']})==len(r['checks']),r['id']
    assert r['assessment']['status']=='not_assessed_no_rtl'
    assert r['assessment']['verdict'] is None
    assert r['assessment']['evidence']['rtl_locations']==[]
    for a in ['previous_ids','next_ids']:assert set(r['dependency_review']['neighbor_context'][a])<=record_ids
    for b in ['possible_predecessor_id','possible_continuation_id']:
        v=r['boundary'][b];assert v is None or v in allunits
    assert set(r['draft']['inherited_notice_record_ids'])<=record_ids
    for ref in r['dependency_review']['explicit_number_references']:
        for target in ref['targets']:
            assert target['id'] in (sections if target['kind']=='section' else headings)
    for ref in r['dependency_review']['related_section_candidates']:assert ref['id'] in sections
    for ref in r['dependency_review']['source_reviewed_links']:assert ref['section_id'] in sections
    for issue in r['open_issues']:
        if 'source_record_ids' in issue:assert set(issue['source_record_ids'])<=record_ids
for t in tables.values():
    assert t['section_id'] in sections
    if t['caption_candidate_id']:assert t['caption_candidate_id'] in headings
    for row in t['rows']:
        assert set(row['source_line_ids'])<=line_ids
        assert set(row['linked_record_ids'])<=record_ids
        for rid in row['linked_record_ids']:
            rec=next(r for r in records if r['id']==rid)
            assert rec['source']['table_id']==t['id'] and rec['source']['row_index']==row['row']

# Meaningful source probes: draft deletion, unresolved references, explicit MRR and arithmetic issue.
mrr=next(r for r in records if r['source']['original_text']=='MRR has a command burst length (BL) 24.')
assert mrr['source']['pdf_page']==339 and mrr['section_id']=='7.8.1'
assert mrr['provenance']['source_reviewed_notes']
assert not mrr['draft']['flags']
deleted=next(r for r in records if r['source']['original_text'].startswith('The CRC-4-SC-8 is a subcode'))
assert 'mostly_deleted_candidate' in deleted['draft']['flags']
crc_ref=next(r for r in records if r['source']['original_text'].startswith('The controller generates the CRC checksum'))
assert any(ref['resolution']=='unresolved' for ref in crc_ref['dependency_review']['explicit_number_references'])
assert any('EVEN(25.6)' in r['source']['original_text'] and r['provenance']['source_reviewed_notes'] for r in records)
mr_update=next(r for r in records if 'The MRUPDATE will not be performed with any CA4 mixed combination' in r['source']['original_text'])
assert mr_update['provenance']['source_reviewed_notes']
matches=load(VAL/'curated_matches.json');assert all(v['matches'] for v in matches.values())
assert all(r['draft']['candidate_is_authoritative'] is False for r in records)

source_path=Path((ROOT/'pdf_path.txt').read_text().strip())
if not source_path.is_absolute():source_path=(ROOT/source_path).resolve()
assert hashlib.sha256(source_path.read_bytes()).hexdigest()==data['source']['sha256']

chapter_counts=[]
for p in sorted((OUT/'chapters').glob('*.json')):
    z=load(p);c=z['chapter'];assert c['record_count']==len(c['records']);chapter_counts.append(len(c['records']))
assert sum(chapter_counts)==len(records)

steps=[
 dict(step=1,title_ko='문구 고정',method='rule_based_source_lookup_then_visual_check',check_ko='PDF339 §7.8.1의 원문과 검정/취소선 없음 상태를 확인한다. 문서 자체는 초안이다.',source_record_ids=[mrr['id']]),
 dict(step=2,title_ko='길이 요구 분리',method='source_reviewed_interpretation_summary',check_ko='명령 burst 24UI와 OP payload 16UI를 분리한다. UI8~23의 위치·DQ1 반전은 별도 요구다.'),
 dict(step=3,title_ko='조건·참조 범위 결정',method='semantic_reference_review_required',check_ko='shared/PSD와 1pX/2pX별 MRR mapping·MR 접근·timing 절을 연결한다. DDR5 BL16 규칙은 적용하지 않는다.'),
 dict(step=4,title_ko='코드 경로 추적',method='static_analysis_pending_no_rtl',check_ko='MRR decode, MR 선택, response queue, serializer length/end guard, DQS enable까지 추적한다.'),
 dict(step=5,title_ko='외부 관측 정의',method='verification_design',check_ko='preamble/postamble을 제외한 UI0~23의 전송과 DQS duration을 waveform에서 측정한다.'),
 dict(step=6,title_ko='구성·경계 시험',method='verification_design',check_ko='허용 구성·주소·OP 값을 변화시키고 23/25UI, 조기 종료, pending overwrite 반례를 찾는다. 명령 간격은 tMRR/tMRD를 지킨다.'),
 dict(step=7,title_ko='근거 기록',method='evidence_collection_pending',check_ko='RTL revision/line, test, 파형, 실제 beat count, 조건 coverage를 남긴다.'),
 dict(step=8,title_ko='판정',method='evidence_gated_decision',check_ko='현재는 RTL·실행 근거가 없으므로 not_assessed_no_rtl이며 통과·미구현·구현률 0%로 해석하지 않는다.')]
example=dict(title='DDR6 MRR BL24 검토 예시',note_ko='8단계는 외부 검토 절차를 설명하기 위한 구성이다. 실제 내부 사고 과정이나 수행된 RTL 검증 로그가 아니다.',source=data['source'],steps=steps,record=mrr,
             related_records=[r for r in records if r['section_id'].startswith('7.8.1')],assessment_policy=data['assessment_policy'])
write(OUT/'DDR6_MRR_example.json',example)

stats=data['statistics']
readme=f'''# DDR6 문장별 구현 판정 체크리스트

요청하신 `.Jason`은 표준 JSON(`.json`, UTF-8)으로 작성했습니다.
이 자료는 **무엇을 확인해야 하는지**를 정리한 검토용 자료입니다. DDR6 RTL이 제공되지 않아 실제 구현 여부나 구현률은 산출하지 않았습니다.

- 원본: {data['source']['original_filename']}
- SHA-256: `{data['source']['sha256']}`
- 527쪽, 17개 chapter, {stats['section_count']}개 번호 절
- 문장 후보 {stats['extracted_sentence_candidates']:,}개(표지/목차/이력 문장 포함), 추가 절·단편 후보 {stats['clause_fragment_candidates']:,}개, 초안 상태 메모 {stats['draft_notices']:,}개
- 체크리스트 record 총 {stats['checklist_records']:,}개
- 표/그림 격자 {stats['detected_grids']:,}개, 보조 행 {stats['supplementary_grid_rows']:,}개
- 원문을 대조해 구체화한 예시 record {stats['source_reviewed_example_records']}개; 나머지 {stats['automatically_generated_records']:,}개는 자동 생성 후 문장별 의미 검토가 필요한 체크리스트입니다.

## 파일

`DDR6_sentence_checklist.json`: 전체 자료. `chapters[].records[]`가 문장/후보 단위입니다.

`chapters/DDR6_chapter_07.json` 등: 장별 분할본. 전체 파일의 부분집합이므로 합쳐서 중복 합산하지 마세요.

`DDR6_checklist_summary.json`: 집계, 공통 8단계, 규칙, 기능별 체크 템플릿, 확인된 초안 문제.

`DDR6_MRR_example.json`: MRR BL24의 8단계 검토 예시와 관련 문장들.

`DDR6_source_ledger.json`: 원문 line, 위치, 색상/취소선 후보, 제외 사유, 나머지 fragment. 전체 JSON의 source_line_ids로 연결합니다.

`DDR6_checklist.schema.json`: 전체 JSON의 구조/미평가 상태 검증용 JSON Schema.

`query_checklist.py`: section/text/id로 문장 조회. 표준 Python만 필요합니다.

## 각 문장 읽는 순서

1. `source`: 원문, PDF 실제 페이지(1부터), 본문 계산 페이지, 위치, 표 행/셀.
2. `draft`와 `open_issues`: 빨강·회색·취소선, TBD, 임시 번호, 문장 경계 등을 먼저 확인합니다. 자동 취소선 제거 문자열은 확정 원문이 아닙니다.
3. `parsed_candidates`, `scope`, `applicability_questions_ko`: 조건/주체/값/모드 후보를 확정합니다. 숫자에는 주소·표 번호도 섞여 있습니다.
4. `checks`와 `verification_plan`: 코드 경로·관측 결과·경계·조합·반례를 구체화합니다. 관련 기능의 체크 템플릿 전체가 그 한 문장의 의무라는 뜻은 아닙니다.
5. `dependency_review`: 명시적 참조, 인접 문장, 의미상 관련 절을 확인합니다. 번호가 존재하는 것과 내용이 맞는 것은 별개입니다.
6. `provenance`: 규칙 매칭과 의미 검토 수준을 확인합니다. 모든 문장에 독립적인 추론/수동 검토를 했다고 표시하지 않습니다.
7. `assessment.evidence`: 향후 RTL revision/file/line, test/assertion, waveform, 실제/기대 결과, 적용 구성과 반례를 입력합니다.

모든 구현 상태는 `not_assessed_no_rtl`, `verdict: null`입니다. 구현률은 `null`이며 0%가 아닙니다.

## 자동 추출의 범위

모든 527쪽의 native text line을 원장에 보존했습니다. 유효 비어있지 않은 line {stats['eligible_nonempty_lines']:,}개가 문장/표/fragment/heading에 배정되었으며 배정 누락은 0개입니다. 이 수치는 **문장 분할과 의미 해석 정확도 100%**를 뜻하지 않습니다.

OCR 및 모든 diagram의 화살표·도형·shading 의미 전사는 수행하지 않았습니다. 문장 경계, cross-page 연결, 표 병합 셀, superscript/수식과 개정 표시는 원본 PDF로 확인해야 합니다. 단편 후보도 남겼으므로 경계 오류가 있어도 원문을 역추적할 수 있습니다. 문장/표/fragment를 중복 합산하지 마세요.

표지의 검정=기통과, 빨강=투표 대상, 회색=DDR5/LPDDR6 참고 범례를 보존했습니다. 취소선 후보는 vector 선 위치로 탐지했습니다. 문서 자체는 PROPOSED draft이며 요구사항 채택 범위를 먼저 결정해야 합니다.

확인된 문제에는 MRR 임시 표/절 번호, CRC의 존재하지 않는 참조 번호, EVEN(25.6)=28 예제 불일치, 붙어서 추출되는 이전/신규 MR 주소, unballoted 절, WUCS 잠정 값이 포함됩니다.

## 조회 예

```bash
python query_checklist.py --section 7.8.1
python query_checklist.py --text 'command burst length'
python query_checklist.py --id {mrr['id']} --full
```

앱에서 큰 JSON 미리보기가 실패하면 ZIP을 다운로드하여 압축을 푼 뒤 VS Code 등으로 장별 파일을 여세요. 원본 PDF는 이 ZIP에 중복 포함하지 않았습니다.
'''
(OUT/'README_ko.md').write_text(readme)
query='''from pathlib import Path
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
'''
(OUT/'query_checklist.py').write_text(query)

result=dict(result='passed',json_schema_valid=True,unique_record_ids=True,all_internal_targets_exist=True,all_source_line_targets_exist=True,
            all_527_pages_present=True,source_pdf_sha256_unchanged=True,all_implementation_verdicts_unassessed=True,
            no_unaccounted_native_text_lines=True,chapter_count_reconciliation=True,all_curated_matchers_hit=True,
            meaningful_source_probes=['MRR BL24 PDF339/7.8.1','CRC-4-SC-8 deletion candidate','CRC unresolved reference','EVEN contradiction example','MRUPDATE mixed CA4 branch'],
            limitations='검증은 JSON/연결/표본 추출/집계에 관한 것이다. 전체 문장 의미의 수작업 검토나 RTL 시뮬레이션이 아니다.',statistics=stats)
write(VAL/'validation_results.json',result);write(OUT/'validation_results.json',result)

# Minified JSON is semantically identical and reduces download/editor overhead.
canonical=json.dumps(data,ensure_ascii=False,separators=(',',':'))+'\n'
(OUT/'DDR6_sentence_checklist.json').write_text(canonical)
assert load(OUT/'DDR6_sentence_checklist.json')==data

files=[p for p in OUT.rglob('*') if p.is_file() and p.suffix!='.zip' and p.name!='MANIFEST.sha256']
manifest='\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(OUT)) for p in sorted(files))+'\n'
(OUT/'MANIFEST.sha256').write_text(manifest)
files.append(OUT/'MANIFEST.sha256')
with zipfile.ZipFile(OUT/'DDR6_checklist_bundle.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(files):z.write(p,p.relative_to(OUT))
with zipfile.ZipFile(OUT/'DDR6_checklist_bundle.zip') as z:assert z.testzip() is None
print(json.dumps(result,ensure_ascii=False,indent=2))
print('FILES',[(p.name,p.stat().st_size) for p in OUT.iterdir() if p.is_file()])
