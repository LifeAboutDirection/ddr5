"""Extract auditable text units without modifying the supplied PDF.

Every retained horizontal text span is accounted for by source block. Tables
and figure labels are kept separately from prose: they are not called sentences.
"""
from pathlib import Path
import bisect, collections, hashlib, json, re, time, argparse
import fitz

ROOT = Path(__file__).parent
parser=argparse.ArgumentParser();parser.add_argument('--pdf',type=Path,required=True)
PDF=parser.parse_args().pdf
doc = fitz.open(PDF)

def normalize(s):
    s = s.replace('\u00ad', '').replace('\u00a0', ' ')
    s = re.sub(r'(?<=[a-z])-\s*\n(?=[a-z])', '', s)
    return re.sub(r'\s+', ' ', s).strip()

outline=[]
for level,title,page,dest in doc.get_toc(False):
    if re.match(r'^\d+(?:\.\d+)*\s',title):
        sid=title.split()[0]
    elif level==1:
        sid={1:'FRONT',5:'CONTENTS',492:'16',493:'17',498:'18',501:'FORM'}.get(page,'OTHER')
    else:continue
    point=dest.get('to')
    y=doc[page-1].rect.height-point.y if point else 60
    outline.append(dict(id=sid,title=title,page=page,y=round(y,2),level=level))
outline.sort(key=lambda x:(x['page'],x['y'],x['level']))
keys=[(o['page'],o['y']-3) for o in outline]
def section(page,y):
    idx=bisect.bisect_right(keys,(page,y))-1
    return outline[max(0,idx)]

ABBREV=['e.g.','i.e.','etc.','vs.','No.','Fig.','min.','max.','typ.','Rev.']
def sentences(text):
    # Keep numeric decimals and section numbers intact. Separate bullets and
    # NOTE clauses before sentence punctuation, including clauses without dots.
    text=re.sub(r'\n\s*(?=(?:NOTE\s*\d+\b|[•●]\s|\d+[)\.]\s+[A-Z]))','\n\n',text)
    text=re.sub(r'\s+(?=NOTE\s*\d+\b)','\n\n',text)
    result=[]
    for part in re.split(r'\n\s*\n|\s*[•●]\s*',text):
        part=normalize(part)
        if not part:continue
        masked=part
        for a in ABBREV:masked=masked.replace(a,a.replace('.','\ue000'))
        masked=re.sub(r'(?<=\d)\.(?=\d)','\ue000',masked)
        masked=re.sub(r'^(\d+)\.\s',lambda m:m[1]+'\ue000 ',masked)
        for s in re.split(r'(?<=[.!?])\s+(?=[A-Za-z0-9(“\[])',masked):
            s=s.replace('\ue000','.')
            if s:result.append(s)
    return result

VERB=re.compile(r'\b(?:shall|must|should|may|can|will|is|are|be|has|have|was|were|does|do|supports?|requires?|provides?|specifies|specify|defines?|refer|see|used|set|enabled|disabled|ignored|reserved|writes?|reads?|reset|indicates?|selects?|applies|apply|changes?|allows?|consists?|include[sd]?|contain[sd]?|shown|determined|measured|programmed|asserted|issued|driven|sampled|latched|prohibited|recommended|expected|expressed|connected|represents?|considered|calculated|limited|operates?|equals?|ensure|follows?|following|means|default)\b',re.I)
def is_prose(s):
    words=re.findall(r'[A-Za-z][A-Za-z_-]*',s)
    return len(words)>=4 and bool(VERB.search(s))

units=[]; pages=[]; tables=[]; removed=collections.Counter(); headings=[]
start=time.time()
for pidx,page in enumerate(doc):
    pn=pidx+1
    allblocks=[]; line_records=[]
    for bidx,b in enumerate(page.get_text('dict')['blocks']):
        if 'lines' not in b:continue
        ls=[]
        for l in b['lines']:
            if abs(l['dir'][1])>0.01:
                removed['rotated_spans']+=len(l['spans']);continue
            spans=[]
            for s in l['spans']:
                if s['bbox'][1]<60 or s['bbox'][1]>755:
                    removed['header_footer_spans']+=1;continue
                if normalize(s['text']) in ['SK Hynix','SK','Hynix']:
                    removed['watermark_spans']+=1;continue
                if not s['text'].strip():continue
                spans.append(s)
            if not spans:continue
            text=''
            prev=None
            for s in spans:
                if prev and s['bbox'][0]-prev['bbox'][2]>1 and not text.endswith(' '):text+=' '
                text+=s['text'];prev=s
            x0=min(s['bbox'][0] for s in spans);y0=min(s['bbox'][1] for s in spans)
            x1=max(s['bbox'][2] for s in spans);y1=max(s['bbox'][3] for s in spans)
            lr=dict(text=text,bbox=[x0,y0,x1,y1],spans=len(spans),size=max(s['size'] for s in spans),bold=all('Bold' in s['font'] for s in spans),block=bidx)
            ls.append(lr);line_records.append(lr)
        if ls:allblocks.append((bidx,ls))
    rawtext='\n'.join(l['text'] for l in sorted(line_records,key=lambda l:(round(l['bbox'][1],1),l['bbox'][0])))
    pages.append(dict(page=pn,printed=pn-32 if 33<=pn<=500 else None,text=rawtext,span_count=sum(l['spans'] for l in line_records)))
    # Extract table geometries only. Table text uses filtered native spans so
    # the diagonal watermark cannot contaminate cell content.
    tbs=[]
    if 33<=pn<=500:
        finder=page.find_tables()
        for ti,t in enumerate(finder.tables):
            if t.col_count>23 or t.row_count<2 or t.col_count<2:continue
            cells=[c for c in t.cells if c]
            box=t.bbox
            texts=[l['text'] for l in line_records if fitz.Rect(box).contains(fitz.Point((l['bbox'][0]+l['bbox'][2])/2,(l['bbox'][1]+l['bbox'][3])/2))]
            joined=normalize(' '.join(texts))
            if re.search(r'Figure\s+\d+\s*[—–-]',joined) and not re.search(r'Function|Parameter|Symbol|Operand|MIN|MAX|DQ0|DDR5-\d+',joined):continue
            tbs.append(dict(bbox=box,index=ti,rows=t.rows,col_count=t.col_count))
    assigned=set()
    for t in tbs:
        ts=section(pn,t['bbox'][1]);tn=f'P{pn:03d}-T{t["index"]+1:02d}'
        tdata=dict(id=tn,page=pn,section=ts['id'],bbox=list(t['bbox']),rows=[])
        for ri,row in enumerate(t['rows']):
            celltexts=[];rowls=[]
            for cell in row.cells:
                if cell is None:celltexts.append('');continue
                rect=fitz.Rect(cell)
                cls=[]
                for li,l in enumerate(line_records):
                    pt=fitz.Point((l['bbox'][0]+l['bbox'][2])/2,(l['bbox'][1]+l['bbox'][3])/2)
                    if rect.contains(pt) and li not in assigned:
                        cls.append(l);assigned.add(li);rowls.append(l)
                celltexts.append(normalize('\n'.join(l['text'] for l in sorted(cls,key=lambda x:(x['bbox'][1],x['bbox'][0])))))
            if not any(celltexts):continue
            txt=' | '.join(celltexts)
            clean=' '.join(c for c in celltexts if c)
            tdata['rows'].append(celltexts)
            note=bool(re.search(r'\bNOTE\s*(?:\d|[A-Z])',clean))
            # A row is one structural item; encoded alternatives remain together.
            for st in sentences(clean) if note else [txt]:
                if not st.strip():continue
                y=min((l['bbox'][1] for l in rowls),default=t['bbox'][1])
                units.append(dict(page=pn,section=section(pn,y)['id'],kind='sentence' if note and is_prose(st) else 'table',text=st,table=tn,row=ri+1,bbox=list(row.bbox),origin='table_note' if note else 'table_row'))
        tables.append(tdata)
    # Rebuild remaining blocks; each line belongs to its actual section.
    byid={id(l):i for i,l in enumerate(line_records)}
    for bidx,ls in allblocks:
        segments=[];cur=[];lastsec=None
        for l in ls:
            if byid[id(l)] in assigned:continue
            sid=section(pn,l['bbox'][1])['id']
            if sid!=lastsec and cur:segments.append((lastsec,cur));cur=[]
            cur.append(l);lastsec=sid
        if cur:segments.append((lastsec,cur))
        for sid,seg in segments:
            txt='\n'.join(l['text'] for l in seg)
            norm=normalize(txt)
            if not norm:continue
            caption=bool(re.match(r'^(?:Table|Figure)\s+\d+\s*[—–-]',norm))
            heading=seg[0]['bold'] and seg[0]['size']>=10 and (bool(re.match(r'^\d+(?:\.\d+)*\s',norm)) or len(norm)<200)
            if caption or heading:
                headings.append(dict(page=pn,section=sid,text=norm,bbox=seg[0]['bbox'],kind='caption' if caption else 'heading'))
                # A heading block sometimes includes a following paragraph.
                if all(l['bold'] and l['size']>=10 for l in seg) or caption:continue
                seg=[l for l in seg if not (l['bold'] and l['size']>=10)]
                txt='\n'.join(l['text'] for l in seg)
            for st in sentences(txt):
                if not st:continue
                units.append(dict(page=pn,section=sid,kind='sentence' if is_prose(st) else 'fragment',text=st,bbox=[min(l['bbox'][0] for l in seg),min(l['bbox'][1] for l in seg),max(l['bbox'][2] for l in seg),max(l['bbox'][3] for l in seg)],origin='body'))
    if pn%50==0:print(f'{pn}/502 pages; {len(units)} units; {time.time()-start:.1f}s',flush=True)
units.sort(key=lambda u:(u['page'],u['bbox'][1],u['bbox'][0]))
counter=collections.Counter()
for u in units:
    counter[u['page']]+=1
    u['id']=f'P{u["page"]:03d}-{counter[u["page"]]:03d}'
    u['chapter']=u['section'].split('.')[0]
result=dict(outline=outline,pages=pages,units=units,tables=tables,headings=headings,removed=dict(removed),source_sha256=hashlib.sha256(PDF.read_bytes()).hexdigest())
(ROOT/'extracted.json').write_text(json.dumps(result,ensure_ascii=False,separators=(',',':')))
with (ROOT/'sentences.txt').open('w') as f:
    for u in units:
        if u['kind']=='sentence':f.write(f'{u["id"]} §{u["section"]} {u["text"]}\n')
print('COUNTS',dict(collections.Counter(u['kind'] for u in units)),flush=True)
