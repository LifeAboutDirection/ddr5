"""Native PDF extraction with a complete line ledger and conservative draft handling."""
from pathlib import Path
import bisect, collections, hashlib, json, re, time
import fitz

ROOT=Path(__file__).parent
PDF=Path((ROOT/'pdf_path.txt').read_text().strip())
if not PDF.is_absolute():PDF=(ROOT/PDF).resolve()
doc=fitz.open(PDF)

def norm(s):
    s=s.replace('\u00ad','').replace('\u00a0',' ')
    s=re.sub(r'(?<=[a-z])-\s*\n(?=[a-z])','',s)
    return re.sub(r'\s+',' ',s).strip()

sections=[]
for level,title,page,dest in doc.get_toc(False):
    m=re.match(r'^(\d+(?:\.\d+)*)\.\s+(.*)',title)
    if not m:continue
    point=dest.get('to')
    sections.append(dict(id=m[1],title=m[2],pdf_page=page,y=round(doc[page-1].rect.height-point.y,2) if point else 60,level=level))
sections.sort(key=lambda s:(s['pdf_page'],s['y'],s['level']))
keys=[(s['pdf_page'],s['y']-3) for s in sections]
def section(p,y):
    k=bisect.bisect_right(keys,(p,y))-1
    return sections[k]['id'] if k>=0 else 'FRONT'

VERB=re.compile(r'\b(?:shall|must|should|may|can|will|is|are|be|has|have|was|were|does|do|supports?|requires?|provides?|specifies|specify|defines?|refer|see|used|set|enabled|disabled|ignored|reserved|writes?|reads?|reset|indicates?|selects?|applies|apply|changes?|allows?|consists?|include[sd]?|contain[sd]?|shown|determined|measured|programmed|asserted|issued|driven|sampled|latched|prohibited|recommended|expected|expressed|connected|represents?|considered|calculated|limited|operates?|equals?|ensure|follows?|following|means|default|issue|wait|verify|keep|maintain|check|exit|enter|disable|enable)\b',re.I)
def prose(s):
    words=re.findall(r'[A-Za-z][A-Za-z_-]*',s)
    if len(words)<3:return False
    if len(re.findall(r'\bFF\b',s))>4:return False
    # Keep declarative sentences even when the finite verb is outside a dictionary.
    if re.search(r'[.!?][”"\')\]]*$',s):return True
    finite=re.search(r'\b(?:shall|must|should|may|can|will|is|are|has|have|was|were|does|supports?|requires?|provides?|specifies|defines?|indicates?|selects?|applies|allows?|consists?|contains?|means|operates?|starts?|maintains?|contributes?|resumes?|clears?|sets?|ends?|checks?|causes?|drives?|receives?|transmits?)\b',s,re.I)
    imperative=re.match(r'^(?:[•●]\s*)?(?:NOTE\s*\d*[:.]?\s*)?(?:\d+[)]\s*)?(?:Issue|Wait|Verify|Keep|Maintain|Check|Exit|Enter|Disable|Enable|Refer|See|Ensure)\b',s)
    return bool(finite or imperative)

def sentence_spans(s):
    # Mask only with equal-length replacements so source offsets remain exact.
    masked=s
    for pattern in [r'\b(?:e\.g\.|i\.e\.|etc\.|vs\.|No\.|Fig\.|min\.|max\.|typ\.|Rev\.|Ch\.|Ref\.|Ex\.)',r'(?<=\w)\.(?=\w)',r'^\s*\d+\.(?=\s)']:
        masked=re.sub(pattern,lambda m:m[0].replace('.','\ue000'),masked,flags=re.I)
    cut=[0]
    # A few revision joins omit the space after a sentence-ending period.
    for m in re.finditer(r'[a-z]{3,}\.(?=[A-Z][a-z]{1,}\b)',s):cut.append(m.end())
    for m in re.finditer(r'(?<=[.!?])\s+(?=[A-Za-z0-9(“\[])|\n\s*(?=(?:NOTE\s*\d*\s*[:.]|[•●]|\d+[)]\s))',masked):
        cut.append(m.end())
    cut=sorted(set(cut+[len(s)]))
    return [(a,b) for a,b in zip(cut,cut[1:]) if norm(s[a:b])]

pages=[];lines=[];units=[];tables=[];captions=[];excluded=collections.Counter()
line_map={};start=time.time()
def add_units(group,origin,table_id=None,row_index=None,cell_index=None,force_kind=None):
    raw='';runs=[]
    for l in group:
        if raw:
            a=len(raw);raw+='\n';runs.append(dict(start=a,end=len(raw),line_id=l['id'],text='\n',color='#000000',strike_candidate=False))
        for r in l['runs']:
            a=len(raw);raw+=r['text'];runs.append(dict(start=a,end=len(raw),line_id=l['id'],**r))
    spans=[(0,len(raw))] if force_kind else sentence_spans(raw)
    for a,b in spans:
        txt=norm(raw[a:b]); rs=[r for r in runs if r['end']>a and r['start']<b]
        if not txt or not rs:continue
        source_ids=list(dict.fromkeys(r['line_id'] for r in rs))
        styles=[]
        for r in rs:
            t=raw[max(a,r['start']):min(b,r['end'])]
            if t:styles.append(dict(text=t,color=r['color'],strike_candidate=r['strike_candidate']))
        p=group[0]['pdf_page'];sid=section(p,group[0]['bbox'][1])
        k=force_kind or ('sentence' if prose(txt) else 'fragment')
        if re.search(r'\b(?:TBD|TBC|Unballoted|To be balloted|DIRECTIONAL)\b',txt,re.I) and len(txt)<160:k='draft_notice'
        u=dict(pdf_page=p,section_id=sid,chapter_id=sid.split('.')[0],kind=k,origin=origin,text=txt,raw_text=raw[a:b],source_line_ids=source_ids,
               bbox=[round(min(line_map[i]['bbox'][j] for i in source_ids) if j<2 else max(line_map[i]['bbox'][j] for i in source_ids),2) for j in range(4)],style_runs=styles)
        if table_id:u.update(table_id=table_id,row_index=row_index,cell_index=cell_index)
        units.append(u)

for pi,page in enumerate(doc):
    pn=pi+1;pl=[];rawdict=page.get_text('rawdict')
    strikes=[]
    for draw in page.get_drawings():
        if draw.get('width') is None or draw['width']>1.2:continue
        for item in draw['items']:
            if item[0]=='l':
                p1,p2=item[1:3]
                if abs(p1.y-p2.y)<.2 and abs(p1.x-p2.x)>1:strikes.append((min(p1.x,p2.x),max(p1.x,p2.x),p1.y))
    for bi,block in enumerate(rawdict['blocks']):
        for li,l in enumerate(block.get('lines',[])):
            lid=f'P{pn:03d}-B{bi:04d}-L{li:03d}';rs=[]
            text=''.join(''.join(c['c'] for c in s['chars']) for s in l['spans'])
            reason=None
            if abs(l['dir'][1])>.01:reason='rotated_text_or_watermark'
            elif pn>=25 and l['bbox'][3]<59:reason='running_header'
            elif pn>=25 and l['bbox'][1]>738:reason='running_footer'
            if reason:excluded[reason]+=1
            prev=None
            for sp in l['spans']:
                if prev and sp['bbox'][0]-prev['bbox'][2]>1 and rs and not rs[-1]['text'].endswith(' '):
                    rs.append(dict(text=' ',color=f"#{sp['color']:06x}",strike_candidate=False))
                for ch in sp['chars']:
                    x0,y0,x1,y1=ch['bbox'];cx=(x0+x1)/2
                    hit=any(a-.3<=cx<=b+.3 and y0+.38*(y1-y0)<=y<=y0+.72*(y1-y0) for a,b,y in strikes)
                    key=(f"#{sp['color']:06x}",hit)
                    if rs and (rs[-1]['color'],rs[-1]['strike_candidate'])==key:rs[-1]['text']+=ch['c']
                    else:rs.append(dict(text=ch['c'],color=key[0],strike_candidate=hit))
                prev=sp
            rec=dict(id=lid,pdf_page=pn,block_index=bi,bbox=[round(x,2) for x in l['bbox']],text=text,runs=rs,
                     size=max((s['size'] for s in l['spans']),default=0),bold=all('Bold' in s['font'] for s in l['spans']),excluded_reason=reason)
            lines.append(rec);line_map[lid]=rec
            if not reason and text.strip():pl.append(rec)
    pages.append(dict(pdf_page=pn,logical_body_page=pn-24 if pn>=25 else None,logical_page_method='body starts at PDF25; printed footer is malformed on alternating pages',
                      extracted_line_count=len([l for l in lines if l['pdf_page']==pn]),body_line_ids=[l['id'] for l in pl],image_count=len(page.get_images()),native_text_chars=len(page.get_text())))
    assigned=set()
    if pn>=25:
        found=page.find_tables()
        for ti,t in enumerate(found.tables):
            if t.col_count<2 or t.row_count<2:continue
            tid=f'P{pn:03d}-T{ti+1:03d}'
            td=dict(id=tid,pdf_page=pn,section_id=section(pn,t.bbox[1]),bbox=[round(v,2) for v in t.bbox],row_count=t.row_count,column_count=t.col_count,rows=[],kind='detected_grid_may_be_table_or_diagram')
            for ri,row in enumerate(t.rows):
                cells=[];allids=[]
                for ci,cell in enumerate(row.cells):
                    if cell is None:cells.append(None);continue
                    rect=fitz.Rect(cell)
                    cls=[l for l in pl if l['id'] not in assigned and rect.contains(fitz.Point((l['bbox'][0]+l['bbox'][2])/2,(l['bbox'][1]+l['bbox'][3])/2))]
                    cls.sort(key=lambda l:(l['bbox'][1],l['bbox'][0]));ids=[l['id'] for l in cls]
                    assigned.update(ids);allids+=ids
                    ct=norm('\n'.join(l['text'] for l in cls));cells.append(dict(text=ct,source_line_ids=ids))
                    if cls and (prose(ct) or re.search(r'\b(?:TBD|Unballoted|To be balloted)\b',ct,re.I)):
                        add_units(cls,'table_cell',tid,ri+1,ci+1)
                td['rows'].append(dict(row=ri+1,cells=cells,source_line_ids=allids))
            if any(r['source_line_ids'] for r in td['rows']):tables.append(td)
    groups=[];cur=[];lastkey=None
    for l in pl:
        if l['id'] in assigned:continue
        key=(l['block_index'],section(pn,l['bbox'][1]))
        txt=norm(l['text'])
        cap=bool(re.match(r'^(?:Table|Figure)\s+\d+\s*[—–-]',txt))
        head=l['bold'] and l['size']>=10.5 and (bool(re.match(r'^\d+(?:\.\d+)*\.\s',txt)) or len(txt)<170)
        if cur and (key!=lastkey or cap or head):groups.append(cur);cur=[]
        if cap or head:
            captions.append(dict(id=f'H{len(captions)+1:05d}',pdf_page=pn,section_id=key[1],kind='caption' if cap else 'heading',text=txt,source_line_ids=[l['id']],bbox=l['bbox']))
            assigned.add(l['id']);lastkey=None;continue
        cur.append(l);lastkey=key
    if cur:groups.append(cur)
    for g in groups:add_units(g,'body' if pn>=25 else 'front_matter')
    if pn%50==0:print(f'{pn}/{len(doc)} pages, {len(units)} units, {len(tables)} grids, {time.time()-start:.1f}s',flush=True)

units.sort(key=lambda u:(u['pdf_page'],u['bbox'][1],u['bbox'][0],u.get('cell_index') or 0))
counts=collections.Counter()
for u in units:
    counts[u['pdf_page']]+=1;u['id']=f"D6-P{u['pdf_page']:03d}-{counts[u['pdf_page']]:04d}"
    u['boundary_review_required']=not bool(re.search(r'[.!?][”"\')\]]*$',u['text'])) and u['kind']=='sentence'
bysec=collections.defaultdict(list)
for u in units:
    if u['kind']=='sentence':bysec[u['section_id']].append(u)
for us in bysec.values():
    for prev,nxt in zip(us,us[1:]):
        if prev['boundary_review_required'] and nxt['text'][:1].islower() and nxt['pdf_page']-prev['pdf_page']<=1:
            prev['possible_continuation_id']=nxt['id'];nxt['possible_predecessor_id']=prev['id']

result=dict(source=dict(path=str(PDF),sha256=hashlib.sha256(PDF.read_bytes()).hexdigest(),pdf_pages=len(doc),metadata=doc.metadata),sections=sections,pages=pages,lines=lines,units=units,tables=tables,headings=captions,excluded_line_counts=dict(excluded))
(ROOT/'extracted.json').write_text(json.dumps(result,ensure_ascii=False,separators=(',',':')))
(ROOT/'sentences.txt').write_text('\n'.join(f"{u['id']} §{u['section_id']} [{u['origin']}] {u['text']}" for u in units if u['kind']=='sentence'))
print('DONE',dict(collections.Counter(u['kind'] for u in units)), 'sections',len(sections),'lines',len(lines),'tables',len(tables),flush=True)
