from pathlib import Path
import collections, copy, hashlib, json, re, zipfile
from checklist_catalog import COMMON_STEPS, PATTERN_RULES, DOMAINS, VERDICT_POLICY
from curated_checks import CURATED

ROOT=Path(__file__).parent; OUT=ROOT/'deliverables'; OUT.mkdir(exist_ok=True)
x=json.loads((ROOT/'extracted.json').read_text())
sections={s['id']:s for s in x['sections']};lm={l['id']:l for l in x['lines']};um={u['id']:u for u in x['units']}
tm={t['id']:t for t in x['tables']}
def norm(s):return re.sub(r'\s+',' ',s).strip()
def dehyphenate(s):return re.sub(r'(?<=[a-z])-\s*\n(?=[a-z])','',s)
def under(s,p):return s==p or s.startswith(p+'.')
def uniq(xs):return list(dict.fromkeys(xs))
def domain_for(s):
    matches=[(len(p),d) for d in DOMAINS for p in d['sections'] if under(s,p)]
    return max(matches,key=lambda v:v[0])[1] if matches else next(d for d in DOMAINS if d['id']=='context')

# Catalog every caption, retaining repeated/sheet captions as distinct locations.
caption_index=collections.defaultdict(list)
for h in x['headings']:
    m=re.match(r'(Table|Figure)\s+(\d+)\s*[—–-]\s*(.*)',h['text'])
    if m:
        h['label_type']=m[1].lower();h['label_number']=m[2]
        caption_index[(m[1].lower(),m[2])].append(h)

table_captions={}
for t in x['tables']:
    cands=[h for h in x['headings'] if h['kind']=='caption' and h['pdf_page']==t['pdf_page'] and h.get('label_type')=='table']
    # Geometric proximity is only a candidate, never a verified caption association.
    if cands:
        best=min(cands,key=lambda h:abs(h['bbox'][1]-t['bbox'][1]) if h['bbox'][1]<=t['bbox'][1]+10 else abs(h['bbox'][1]-t['bbox'][3])+30)
        table_captions[t['id']]=best['id']

rules={r['id']:re.compile(r['pattern'],re.I if r['id'] not in ['R_TIMING','R_REGISTER'] else 0) for r in PATTERN_RULES}

def evidence_template():
    return dict(rtl_revision=None,rtl_locations=[],test_ids=[],assertion_ids=[],expected_observations=[],actual_observations=[],waveform_paths=[],covered_configurations=[],counterexamples=[],reviewer=None)

def style_summary(u):
    cnt=collections.Counter();strike=0;total=0
    for s in u['style_runs']:
        n=len(s['text'].strip());cnt[s['color']]+=n;total+=n
        if s['strike_candidate']:strike+=n
    flags=[]
    if any(c.lower() in ['#ff0000','#c00000'] for c in cnt):flags.append('red_ballot_text_present')
    if any(c.lower() in ['#ababab','#999999'] for c in cnt):flags.append('gray_reference_text_present')
    if strike:flags.append('strike_geometry_candidate_present')
    if total and strike/total>.92:flags.append('mostly_deleted_candidate')
    proposed=''.join(s['text'] for s in u['style_runs'] if not s['strike_candidate'])
    return dict(color_character_counts=dict(cnt),strike_candidate_characters=strike,flags=flags,
                candidate_after_strike_removal=norm(dehyphenate(proposed)),candidate_is_authoritative=False,
                policy_ko='원문 색상 범례(PDF1)에 따른 후보 분류. 취소선은 텍스트 중앙을 가로지르는 vector 선으로 탐지하므로 PDF 시각 확인 필요. 삭제 후보를 제거한 문자열은 편의용이며 채택된 규범 문구가 아니다.')

def reference_candidates(u):
    result=[];text=u['text']
    pattern=r'\b(Sections?|Tables?|Figures?|Chapters?)\s+([0-9xX]+(?:\.[0-9xXyY]+)*)(?:\s*[-–]\s*(\d+))?'
    for m in re.finditer(pattern,text,re.I):
        typ=m[1].lower().rstrip('s');labels=[m[2]]
        if m[3] and m[2].isdigit() and int(m[3])>=int(m[2]) and int(m[3])-int(m[2])<30:labels=[str(i) for i in range(int(m[2]),int(m[3])+1)]
        for label in labels:
            targets=[]
            if typ in ['section','chapter'] and label in sections:targets=[dict(kind='section',id=label,pdf_page=sections[label]['pdf_page'],title=sections[label]['title'])]
            if typ in ['table','figure']:
                targets=[dict(kind='caption',id=h['id'],pdf_page=h['pdf_page'],title=h['text']) for h in caption_index.get((typ,label),[])]
            flags=[]
            if not targets:flags.append('placeholder_or_unresolved_number')
            elif min(abs(t['pdf_page']-u['pdf_page']) for t in targets)>30:flags.append('remote_number_match_check_for_stale_ballot_reference')
            if m[3]:flags.append('range_expansion_candidate')
            result.append(dict(literal=m[0],type=typ,label=label,method='rule_based_number_lookup',resolution='number_matched_content_unverified' if targets else 'unresolved',targets=targets,flags=flags,
                               semantic_confirmation_required=True))
    return result

def entities(t):
    return dict(
      registers=uniq(m[0] for m in rules['R_REGISTER'].finditer(t)),
      timings=uniq(re.findall(r'\bt[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)?\b',t)),
      commands=uniq(re.findall(r'\b(?:ACTIVATE|ACT|PRECHARGE|PREab|PREpb|PREdb|PREqb|READ|WRITE|RD|WR|WRA|MRR|MRW|MRUPDATE|MCME|DES|NOP|REFab|REFdb|REFqb|REF|RFM|PRFM|SRE|SRX|PDE|PDX|NT_ODT)\b',t)),
      configurations=uniq(re.findall(r'\b(?:[12]p(?:3|6|12|X)|MD_OFF|MD_8b|MD_16b|FSP-WR|FSP-OP|PSD[01]?)\b',t)),
      signals=uniq(re.findall(r'\b(?:DQ(?:S)?(?:_[tc])?|CK(?:_[tc])?|CA|CS|ALERT(?:_n)?|RESET_n|OP|MA|MRA)(?:\s*\[[^\]]+\]|\d+)?',t)),
      numeric_literals=uniq(re.findall(r'(?<![A-Za-z_])(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[bBhH]|\s*(?:bits?|UI|nCK|tCK|ps|ns|us|ms|mV|MHz|GHz|Mbps|%))?)(?![A-Za-z_])',t)),
      modal_words=uniq(re.findall(r'\b(?:shall|must|should|may|can|will|required|illegal|prohibited)\b',t,re.I)))

def clause_candidates(t):
    chunks=[c.strip() for c in re.split(r';\s*|(?<=,)\s*(?=(?:but|and|while|whereas)\b)',t) if c.strip()]
    cond=[]
    for m in rules['R_CONDITION'].finditer(t):
        end=t.find(',',m.end());end=len(t) if end<0 else end
        cond.append(dict(keyword=m[0],text=t[m.start():end],binding_verified=False))
    return dict(atomic_clause_candidates=chunks,condition_candidates=cond,subject_effect_binding_status='semantic_review_required')

def scope_candidate(t,chapter):
    host=bool(re.search(r'\b(?:host|controller|system)\b',t,re.I));dram=bool(re.search(r'\b(?:DRAM|device|DDR6)\b',t,re.I))
    analog=bool(re.search(r'\b(?:voltage|current|impedance|resistan\w*|capacitance|slew|jitter|eye|mV|ohm|temperature|analog|physical|supply)\b|Ω',t,re.I))
    digital=bool(re.search(r'\b(?:MR\w+|command|bit|register|cycle|state|clock|counter|enable\w*|disable\w*|latency|timing|reset|t[A-Z]\w+|UI|DQ\w*|CA|CS|ALERT|sample\w*|read|write|data|REF\w*)\b',t))
    if chapter in ['FRONT','1','17']:kind='context_or_documentation_candidate'
    elif analog and digital:kind='mixed_digital_and_physical_candidate'
    elif analog:kind='physical_evidence_candidate'
    elif digital:kind='digital_behavior_candidate'
    else:kind='needs_semantic_scope_review'
    return dict(kind=kind,owner_candidate='host_and_device' if host and dram else 'host_or_system' if host else 'device_or_unspecified',
                rule_basis='lexical_signals_plus_context_chapter',confirmed=False,implementation_denominator_inclusion=None)

def applicability_questions(u,e,st):
    qs=[]
    if st['flags']:qs.append('색상·취소선 후보를 확인하여 이 문구 전체 또는 일부를 채택할지 확정한다.')
    if e['configurations']:qs.append('원문에 나온 구성/모드 '+', '.join(e['configurations'])+'의 한정 범위와 인접 예외를 확인한다.')
    if e['registers']:qs.append('MR 주소·필드 '+', '.join(e['registers'])+'의 최신 map, 접근 속성, shared/PSD/FSP 적용 범위를 확인한다.')
    if not qs:qs.append('상위 절과 앞뒤 문장의 전제·정의·예외를 확인하여 적용 범위를 확정한다.')
    return qs

curated_hits=collections.Counter()
curated_index=[]
def curated(u):
    found=[]
    for i,(sec,needle,summary,checks,deps,reason) in enumerate(CURATED):
        if under(u['section_id'],sec) and needle.lower() in u['text'].lower():
            curated_hits[i]+=1
            found.append(dict(id=f'C{i+1:03d}',summary_ko=summary,checks_ko=checks,related_section_ids=[s for s in deps if s in sections],
                              interpretation_summary_ko=reason,method='source_reviewed_checklist_design_no_rtl_review',source_match=needle))
    return found

def candidate_fragment(u):
    if u['kind']!='fragment' or u['chapter_id'] in ['FRONT','17']:return False
    t=u['text'];words=re.findall(r'\b[A-Za-z]{2,}\b',t)
    return len(words)>=9 and len(re.findall(r'[\[\]=<>]',t))<9 and len(re.findall(r'\bFF\b',t))<3

selected=[u for u in x['units'] if u['kind'] in ['sentence','draft_notice'] or candidate_fragment(u)]
selected_ids={u['id'] for u in selected}
section_records=collections.defaultdict(list)
for u in selected:section_records[u['section_id']].append(u)
neighbors={}
for sid,us in section_records.items():
    for i,u in enumerate(us):
        neighbors[u['id']]=dict(previous_ids=[us[i-1]['id']] if i else [],next_ids=[us[i+1]['id']] if i+1<len(us) else [],
                                 method='same_section_document_order_context_candidate',meaning_verified=False)

draft_notices=[u for u in x['units'] if re.search(r'To be balloted|Unballoted|\[DIRECTIONAL\]',u['text'],re.I) and len(u['text'])<150]
def inherited_notices(u):
    return [v['id'] for v in draft_notices if v['id']!=u['id'] and under(u['section_id'],v['section_id']) and v['pdf_page']<=u['pdf_page']]

records=[]
for u in selected:
    t=u['text'];sid=u['section_id'];d=domain_for(sid);e=entities(t);st=style_summary(u);refs=reference_candidates(u);cl=clause_candidates(t);special=curated(u)
    matches=[]
    for r in PATTERN_RULES:
        ms=list(rules[r['id']].finditer(t))
        if ms:matches.append(dict(rule_id=r['id'],matched_text=uniq(m[0] for m in ms)))
    blockers=[]
    for m in rules['R_DRAFT'].finditer(t):blockers.append(dict(type='draft_placeholder',literal=m[0],resolution=None))
    if st['flags']:blockers.append(dict(type='draft_style_review',flags=st['flags'],resolution=None))
    inherited=inherited_notices(u)
    if inherited:blockers.append(dict(type='inherited_unballoted_or_directional_notice',source_record_ids=inherited,resolution=None))
    if u.get('boundary_review_required') or u['kind']=='fragment':blockers.append(dict(type='sentence_boundary_or_fragment_review',resolution=None))
    for r in refs:
        if r['flags']:blockers.append(dict(type='reference_review',literal=r['literal'],flags=r['flags'],resolution=None))
    if re.search(r'\bMR[0-9A-F]{3,}\b',t):blockers.append(dict(type='possible_old_new_register_address_join',resolution=None))
    sc=scope_candidate(t,u['chapter_id'])
    ck=[dict(id='LOCAL_REQUIREMENT',method='source_statement_to_property_requires_semantic_review',
             check_ko='아래 원문을 전제 ⇒ 관측 결과 형태로 확정하고, 각 절의 AND/OR·부정·허용 여부를 유지한다.',source_statement=t,
             evidence_expected_ko='적용 조건, 코드 경로, 기대/실제 값 및 관측 신호. 원문을 반복하는 주석만으로 충족 처리하지 않음.')]
    for j,q in enumerate(d['checks']):ck.append(dict(id=f"D_{d['id']}_{j+1}",method='section_selected_review_template',check_ko=q,applicability='문장이 이 기능의 해당 세부 동작을 규정할 때 적용; 모든 목록을 이 문장의 의무로 간주하지 않음'))
    if e['timings']:
        ck.append(dict(id='TIMING_BINDING',method='rule_based_token_binding_then_test_design',parameters=e['timings'],
                       check_ko='각 timing 이름의 정의·min/max·단위·speed/FSP·기준 edge를 표에서 확정한다. 허용되는 관측 단위에서 경계−ε/경계/경계+ε를 비교한다. ε는 시간 해상도나 1cycle 중 요구에 맞게 선택한다.'))
    if e['registers']:
        ck.append(dict(id='REGISTER_BINDING',method='rule_based_token_binding_then_static_trace',register_literals=e['registers'],
                       check_ko='주소 이름을 찾은 뒤 reset/read/write/효과 경로를 추적한다. redline 주소 병합·MRxx·동일 번호의 문맥 차이를 먼저 해결한다.'))
    qwords=uniq(m[0] for m in rules['R_QUANTIFIER'].finditer(t))
    if qwords:ck.append(dict(id='QUANTIFIER_COVERAGE',method='rule_based_trigger_semantic_scope_required',quantifiers=qwords,
                           check_ko='한정 대상 집합을 정의하고 경계·누락 구성·반대 조건을 검증한다. 모든 주소/모드라는 문구를 단일 정상 케이스로 입증하지 않는다.'))
    if rules['R_PERMISSION'].search(t):ck.append(dict(id='PERMISSION_VS_OBLIGATION',method='semantic_review_required',check_ko='may/can/should가 허용·기능 지원·권고 중 무엇인지 확정한다. 허용된 여러 동작 중 한 구현을 선택했다는 이유만으로 fail하지 않는다.'))
    if rules['R_NEGATION'].search(t):ck.append(dict(id='NEGATIVE_EFFECT',method='rule_trigger_then_behavioral_test_design',check_ko='금지되는 결과와 적용 전제를 확정한 뒤 그 결과의 부재를 관측한다. 경고 출력, 동작 차단, undefined 동작, host 준수 의무를 구분한다.'))
    if u.get('table_id'):ck.append(dict(id='TABLE_CONTEXT',method='rule_based_geometry_then_semantic_review',table_id=u['table_id'],row_index=u['row_index'],cell_index=u['cell_index'],check_ko='같은 행의 label/attribute/default와 열 header·footnote를 결합해 이 문장의 주어·범위를 확정한다. 병합 셀은 PDF에서 확인한다.'))
    for sp in special:
        for j,q in enumerate(sp['checks_ko']):ck.append(dict(id=sp['id']+f'-{j+1}',method=sp['method'],check_ko=q))
    boundary=dict(review_required=u.get('boundary_review_required',False) or u['kind']=='fragment',
                  possible_predecessor_id=u.get('possible_predecessor_id'),possible_continuation_id=u.get('possible_continuation_id'))
    records.append(dict(id=u['id'],chapter_id=u['chapter_id'],section_id=sid,record_kind='sentence_candidate' if u['kind']=='sentence' else 'draft_notice' if u['kind']=='draft_notice' else 'clause_fragment_candidate',
                        source=dict(pdf_page=u['pdf_page'],logical_body_page=u['pdf_page']-24 if u['pdf_page']>=25 else None,bbox=u['bbox'],source_line_ids=u['source_line_ids'],origin=u['origin'],original_text=t,raw_text=u['raw_text'],
                                    table_id=u.get('table_id'),row_index=u.get('row_index'),cell_index=u.get('cell_index')),
                        draft=dict(**st,style_runs=u['style_runs'],inherited_notice_record_ids=inherited),
                        boundary=boundary,scope=sc,parsed_candidates=dict(**e,**cl),applicability_questions_ko=applicability_questions(u,e,st),
                        common_step_ids=[s[0] for s in COMMON_STEPS],domain_id=d['id'],checks=ck,
                        verification_plan=dict(status='proposed_not_executed',
                            baseline=dict(condition_quotes=[c['text'] for c in cl['condition_candidates']],command_candidates=e['commands'],
                                setup_register_candidates=e['registers'],observable_candidates=e['signals'],
                                expected_property_source=t,action_ko='조건·주체·효과를 확정한 뒤 합법 자극을 만들고 이 문장의 결과를 관측한다. 주어/상태가 생략되어 있으면 인접 문장 또는 표 행에서 보충한다.'),
                            boundary=dict(timing_candidates=e['timings'],literal_numeric_candidates=e['numeric_literals'],
                                action_ko='추출된 숫자가 값/주소/index/표 번호 중 무엇인지 먼저 구분한다. 유효 범위·시간의 경계−ε/경계/경계+ε를 검사하며 주소나 표 번호를 무조건 경계값으로 사용하지 않는다.'),
                            combinations=dict(explicit_configurations=e['configurations'],quantifier_candidates=qwords,
                                action_ko='명시된 적용 구성과 상위 절의 숨은 전제를 포함해 coverage matrix를 만든다. 지원하지 않는 조합과 undefined 결과는 별도 분류한다.'),
                            counterexample_design_ko='이 문장의 전제가 참인데 요구 결과가 빠지거나 반대로 나타나는 최소 반례를 정의한다. 허용/권고 문장은 mandatory 결과로 바꾸지 않는다.',
                            evidence_completion_required=['rtl_revision','rtl_locations','test_ids_or_assertion_ids','expected_and_actual_observations','covered_configurations']),
                        dependency_review=dict(explicit_number_references=refs,neighbor_context=neighbors[u['id']],
                            related_section_candidates=[dict(id=s,method='domain_review_template',requiredness='candidate_requires_semantic_confirmation') for s in d['related'] if s in sections],
                            source_reviewed_links=[dict(section_id=s,reason_ko=sp['interpretation_summary_ko']) for sp in special for s in sp['related_section_ids']],
                            rule_ko='번호·같은 행·인접 문장은 기계적으로 연결 가능. 실제 전제/예외/정의 관계와 우선순위는 의미 검토가 필요하며 다른 문장 pass/fail을 복사하지 않는다.'),
                        provenance=dict(generation='deterministic_extraction_and_check_templates',matched_rules=matches,
                            semantic_review_status='selected_source_reviewed_example' if special else 'generated_requires_sentence_review',
                            source_reviewed_notes=special,independent_per_sentence_inference_performed=False),
                        open_issues=blockers,assessment=dict(status='not_assessed_no_rtl',verdict=None,evidence=evidence_template())))

record_map={r['id']:r for r in records}

# Table rows are supplementary structured requirements, never added to sentence counts.
table_records=[]
for t in x['tables']:
    d=domain_for(t['section_id']);tt=copy.deepcopy(t)
    tt['caption_candidate_id']=table_captions.get(t['id']);tt['caption_link_verified']=False
    tt['domain_id']=d['id'];tt['common_step_ids']=[s[0] for s in COMMON_STEPS]
    tt['review_checks_ko']=[
        '행·열 header, 병합 셀, 단위, 주석 번호와 개정 색상을 PDF에서 확인하고 유효 요구를 확정한다.',
        'encoding 표는 모든 legal/reserved code와 default/속성을, timing 표는 command pair·bank 관계·min/max·단위·산식을, mapping 표는 lane×UI별 bit 위치를 점검한다.',
        '표 내부 문장이 별도 record로도 추출된 경우 같은 요구를 구현률에 중복 합산하지 않는다.',
        '격자 탐지는 timing diagram·그림의 matrix도 포함할 수 있다. table/figure 구분과 도형의 의미는 원문에서 확인한다.']
    for row in tt['rows']:
        row['id']=f"{t['id']}-R{row['row']:03d}";row['status']='not_assessed_no_rtl'
        row['linked_record_ids']=[r['id'] for r in records if r['source']['table_id']==t['id'] and r['source']['row_index']==row['row']]
        row['literal_row']=' | '.join(c['text'] if c else '' for c in row['cells'])
        row['checks_to_apply']=['table.review_checks_ko',f"domains.{d['id']}.checks"]
    table_records.append(tt)

chapters=[]
for cid in ['FRONT']+[str(i) for i in range(1,18)]:
    cs=[s for s in x['sections'] if s['id'].split('.')[0]==cid]
    cr=[r for r in records if r['chapter_id']==cid]
    chapters.append(dict(id=cid,title=sections[cid]['title'] if cid in sections else 'Cover and front matter',
                         sections=cs,record_count=len(cr),sentence_candidate_count=sum(r['record_kind']=='sentence_candidate' for r in cr),
                         table_ids=[t['id'] for t in table_records if t['section_id'].split('.')[0]==cid],records=cr))

# Count extraction accounting, not semantic completeness.
covered=set(i for u in x['units'] for i in u['source_line_ids'])
covered.update(i for h in x['headings'] for i in h['source_line_ids'])
covered.update(i for t in x['tables'] for row in t['rows'] for i in row['source_line_ids'])
eligible=[l for l in x['lines'] if not l['excluded_reason'] and l['text'].strip()]
uncovered=[l['id'] for l in eligible if l['id'] not in covered]
stats=dict(pdf_pages=x['source']['pdf_pages'],chapter_count=17,section_count=len(sections),
           extracted_sentence_candidates=sum(r['record_kind']=='sentence_candidate' for r in records),
           body_sentence_candidates=sum(r['record_kind']=='sentence_candidate' and r['chapter_id'] not in ['FRONT','17'] for r in records),
           draft_notices=sum(r['record_kind']=='draft_notice' for r in records),clause_fragment_candidates=sum(r['record_kind']=='clause_fragment_candidate' for r in records),
           checklist_records=len(records),source_reviewed_example_records=sum(bool(r['provenance']['source_reviewed_notes']) for r in records),
           automatically_generated_records=sum(not r['provenance']['source_reviewed_notes'] for r in records),
           detected_grids=len(table_records),supplementary_grid_rows=sum(len(t['rows']) for t in table_records),
           supplementary_fragments=sum(u['id'] not in selected_ids for u in x['units']),
           native_text_lines=len(x['lines']),eligible_nonempty_lines=len(eligible),accounted_eligible_lines=len(eligible)-len(uncovered),uncovered_line_ids=uncovered,
           excluded_line_counts=x['excluded_line_counts'],records_with_open_issues=sum(bool(r['open_issues']) for r in records),
           implementation_assessed_records=0,implementation_rate=None,
           coverage_meaning_ko='모든 native text line을 원장에 보존하고 제외/문장/표/fragment/header에 배정했는지의 기계적 검사이다. 문장 분할·그림 해석·요구사항 분해·참조 의미의 100% 정확성을 뜻하지 않는다.')

issues=[
 dict(id='I_DRAFT_COLORS',source_pdf_pages=[1],issue_ko='검정=기통과, 빨강=투표 대상, 회색=LPDDR6/DDR5 참고. 문서 전체는 PROPOSED draft이다.',required_action_ko='구현 기준으로 채택할 개정 범위를 먼저 정하고 삭제/참고 문구를 요구사항에서 분리한다.'),
 dict(id='I_MRR_REFERENCE',source_pdf_pages=[339,340,341,342,343],section_ids=['7.8.1','7.8.1.2'],issue_ko='MRR 본문의 Table 1-6/7/8와 Section x.x.y는 현재 편집 번호와 일치 여부를 확인해야 한다.',required_action_ko='MRR 매핑/타이밍 표 및 §6.3/§7.1.1/§8.1.4/§8.2와 의미를 대조하고 승인된 연결을 기록한다.'),
 dict(id='I_CRC_REFERENCE',source_pdf_pages=[408,409],section_ids=['7.9.8.1','7.9.8.2'],issue_ko='Section 1.1.4.3/1.1.4.4는 현재 목차에 없다.',required_action_ko='CRC packet mapping §7.9.8.3~4를 의미상 후보로 검토한다. 자동으로 번호를 대체하지 않는다.'),
 dict(id='I_EVEN_EXAMPLE',source_pdf_pages=[265],section_ids=['7.2.4'],issue_ko='EVEN(25.6)=28 예제가 next even integer 정의와 불일치한다(통상 정의라면 26).',required_action_ko='4의 배수 제약인지 오타인지 명세 확인 후 기대 timing을 정한다.'),
 dict(id='I_REGISTER_REDLINE',source_pdf_pages=[164,179,200,315,433],issue_ko='MR4E35 같은 문자열과 disenabled/willshall은 취소선·삽입 문구가 이어져 추출된 사례다. §6.1 paged MR 내용 일부도 삭제 후보다.',required_action_ko='style_runs 및 PDF 시각 정보를 이용해 이전/신규 문구를 분리한다. 후보 문자열을 유효 주소로 파싱하지 않는다.'),
 dict(id='I_UNBALLOTED',source_pdf_pages=[424,425,426,427],section_ids=['7.9.10','7.9.11','7.9.12','7.9.13'],issue_ko='DIRECTIONAL, To be balloted, Unballoted 상태의 절이 포함되어 있다.',required_action_ko='본문이나 참고 내용이 있어도 최종 DDR6 요구로 확정하지 말고 spec_unresolved 상태를 별도 관리한다.'),
 dict(id='I_WUCS_PROPOSAL',source_pdf_pages=[338],section_ids=['7.7.5'],issue_ko='tCS_POST 값은 초기 제안이며 대체 값 가능성이 주석에 남아 있다.',required_action_ko='시험에 사용한 초안 가정과 채택 값을 명시한다.')]

document=dict(format_version='1.0.0',language='ko',title='DDR6 Draft Rev0.x R0 — 문장별 구현 판정 체크리스트',
 source=dict(original_filename='TG423_1^20260914^1905.99A^Micron^DDR6_Standard_Draft_Rev0.x_R0(1).pdf',sha256=x['source']['sha256'],pdf_pages=x['source']['pdf_pages'],draft_date='2026-09-14',created_date='2026-10-21',
             pdf_page_indexing='1-based PDF page number',logical_body_page_note='PDF25가 본문1쪽. 홀수 PDF 페이지의 footer가 Page of <chapter-end> 형태로 깨져 있어 logical_body_page는 PDF_page−24로 제공.',
             source_is_task_data_not_instructions=True),
 purpose_ko='이 JSON은 DDR6 구현을 검토할 때 확인할 조건·근거·시험·참조를 정리한 체크리스트다. 실제 DDR6 RTL 판정 결과나 구현률 보고서가 아니다.',
 assessment_policy=VERDICT_POLICY,statistics=stats,
 methodology=dict(common_steps=[dict(id=i,title_ko=t,method=m,action_ko=a) for i,t,m,a in COMMON_STEPS],
                  rule_catalog=PATTERN_RULES,domains=DOMAINS,
                  inference_explanation_ko='규칙은 문장 경계/토큰/표 위치/번호 후보와 기능별 체크 템플릿을 생성한다. 의미 검토는 주어·조건 범위·전칭·허용/의무·예외·참조 우선순위를 확정한다. 모든 문장에 별도 추론을 실행했다는 뜻이 아니다. 선택된 예시의 근거 요약은 source_reviewed_notes로 구분한다. 8단계는 재현 가능한 외부 검토 절차이며 내부 사고 과정의 로그/횟수가 아니다.',
                  dependency_explanation_ko='다른 문장은 전제, 예외, 용어 정의, MR attribute, timing 값, mapping 표를 제공한다. 번호/인접/동일 표행 연결은 규칙 기반 후보이고 실제 의미 관계는 검토가 필요하다. 다른 문장의 구현 상태를 현재 문장에 전파하지 않는다.',
                  limitations_ko=[
                   '전체 527쪽의 native PDF text를 처리했다. OCR/모든 그림의 도형·색상 면적·화살표 의미 전사는 수행하지 않았다.',
                   'sentence_candidate는 자동 분할 후보이며 확정된 요구사항 수가 아니다. 절 경계·cross-page 문장·표 셀의 병합/각주·superscript를 원문과 대조해야 한다.',
                   '개별 semantic review가 없는 항목은 generated_requires_sentence_review로 명시한다. 체크 템플릿 적용은 독립적인 문장별 검토 완료를 의미하지 않는다.',
                   '색상과 취소선 후보를 보존하지만 개정 문구 자동 채택은 하지 않는다. candidate_after_strike_removal은 검토 편의용이다.',
                   '디지털/물리/host 범위는 후보 분류다. 물리 chapter라도 MR·timing·논리 요구는 별도로 검토해야 한다.',
                   '각 문장의 기능별 체크 목록은 연관 확인 항목이다. 모든 목록이 그 한 문장에 규정된 의무라는 뜻은 아니다.',
                   '코드 검색·정적 분석·simulation·formal proof를 DDR6 대상으로 실행하지 않았다. 모든 구현 상태는 not_assessed_no_rtl이다.']),
 known_spec_review_issues=issues,
 evidence_record_template=evidence_template(),
 chapters=chapters,table_supplements=table_records,
 source_headings_and_captions=x['headings'],
 page_ledger=x['pages'],
 source_ledger_companion='DDR6_source_ledger.json',
 schema_file='DDR6_checklist.schema.json')

def writejson(path,data,pretty=True):path.write_text(json.dumps(data,ensure_ascii=False,indent=2 if pretty else None,separators=None if pretty else (',',':'))+'\n')
writejson(OUT/'DDR6_sentence_checklist.json',document)
writejson(OUT/'DDR6_checklist_summary.json',dict(title=document['title'],source=document['source'],statistics=stats,known_spec_review_issues=issues,methodology=document['methodology'],assessment_policy=VERDICT_POLICY,
                                             chapters=[{k:v for k,v in c.items() if k not in ['records','sections']} for c in chapters]))
ledger=dict(source=document['source'],coverage_statistics=stats,lines=x['lines'],unselected_units=[u for u in x['units'] if u['id'] not in selected_ids],
            note_ko='모든 native text line 및 제외 사유 보존. unselected_units는 짧은 표/그림 label·fragment·목차 등이므로 문장 수에 합산하지 않음. 그래도 source_line_ids로 역추적 가능.')
writejson(OUT/'DDR6_source_ledger.json',ledger,False)
chapter_dir=OUT/'chapters';chapter_dir.mkdir(exist_ok=True)
for c in chapters:
    stem='00_front' if c['id']=='FRONT' else f"{int(c['id']):02d}"
    data=dict(format_version='1.0.0',source=document['source'],assessment_policy=VERDICT_POLICY,methodology=document['methodology'],chapter=c,
              table_supplements=[t for t in table_records if t['id'] in c['table_ids']],source_ledger_companion='../DDR6_source_ledger.json',
              global_references_note_ko='다른 chapter/record/caption 참조는 DDR6_sentence_checklist.json에서 찾는다. 각 chapter 파일은 전체의 중복 부분집합이다.')
    writejson(chapter_dir/f'DDR6_chapter_{stem}.json',data)

writejson(ROOT/'validation'/'build_statistics.json',stats)
writejson(ROOT/'validation'/'curated_matches.json',{f'C{i+1:03d}':dict(matches=curated_hits[i],needle=row[1]) for i,row in enumerate(CURATED)})
print(json.dumps(stats,ensure_ascii=False,indent=2))
print('UNMATCHED CURATED',[row[1] for i,row in enumerate(CURATED) if not curated_hits[i]])
