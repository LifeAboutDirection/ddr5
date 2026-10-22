"""Create a smaller browser report without changing any audit judgments.
All JSON data is losslessly gzip-compressed. The original PDF is a sibling file.
"""
from pathlib import Path
import base64,gzip,json,re,shutil,hashlib,zipfile
ROOT=Path(__file__).resolve().parent
OUT=ROOT/'deliverables/browser';OUT.mkdir(exist_ok=True)
original=(ROOT/'deliverables/JESD79-5B_ddr5_sentence_audit.html').read_text()
data=(ROOT/'deliverables/audit-data.json').read_bytes()
D=json.loads(data)
compressed=base64.b64encode(gzip.compress(data,compresslevel=9,mtime=0)).decode()
pdf=ROOT.parent/'inputs/JESD79-5B_v1-2.pdf'
if not pdf.exists():pdf=next(Path('/workspace/attachments').glob('*/JESD79-5B_v1-2.pdf'))
assert hashlib.sha256(pdf.read_bytes()).hexdigest()==D['meta']['pdf_sha256']
shutil.copyfile(pdf,OUT/pdf.name)
html=re.sub(r'<script id="audit-data" type="application/json">.*?</script>',f'<script id="audit-gzip" type="application/octet-stream">{compressed}</script>',original,flags=re.S)
html=re.sub(r'<script id="pdfdata" type="application/octet-stream">.*?</script>','',html,flags=re.S)
html=html.replace("const DATA=JSON.parse(document.getElementById('audit-data').textContent);","const DATA=window.__AUDIT_DATA; delete window.__AUDIT_DATA;")
pdfcode='''let pdfURL='';
const PDF_FILENAME='JESD79-5B_v1-2.pdf';
function getPdfURL(){return pdfURL||new URL(PDF_FILENAME,location.href).href}
function choosePdf(page){
 const input=document.createElement('input');input.type='file';input.accept='.pdf,application/pdf';input.id='local-pdf-picker';input.style.display='none';document.body.appendChild(input);
 input.onchange=async()=>{const file=input.files[0];if(!file)return;
  if(window.crypto&&crypto.subtle){const sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await file.arrayBuffer())),b=>b.toString(16).padStart(2,'0')).join('');
   if(sha!==DATA.meta.pdf_sha256){showModal('원문 PDF 확인 필요','<p>선택한 파일이 분석에 사용한 PDF와 다릅니다. 사용자 제공 JESD79-5B_v1-2.pdf 또는 ZIP에 동봉한 원문을 선택하세요.</p>');input.remove();return}}
  if(pdfURL)URL.revokeObjectURL(pdfURL);pdfURL=URL.createObjectURL(file);input.remove();openPdf(page);
 };input.click();
}
function openPdf(page){page=Math.max(1,Math.min(502,Number(page)||1));const url=getPdfURL()+'#page='+page;
 showModal(`JESD79-5B · PDF ${page}p / 인쇄 ${DATA.pages[page-1].printed??'—'}p`,
 `<div class="focus-note">${pdfURL?'선택한 원문 PDF를 표시합니다.':'경량판은 HTML과 같은 폴더의 원문 PDF를 엽니다. PDF가 보이지 않으면 아래에서 원문 파일을 선택하세요.'} 파일 선택 시 브라우저 안에서만 사용하며 서버로 업로드하지 않습니다.</div><div class="actions"><button class="primary" onclick="choosePdf(${page})">원문 PDF 선택</button><a href="${url}" target="_blank" rel="noopener">PDF 새 탭에서 열기</a></div><iframe class="pdf-frame" title="JESD79-5B 원문 PDF" src="${url}"></iframe>`);
}
'''
html=re.sub(r"let pdfURL='';.*?(?=function showPageText)",lambda m:pdfcode,html,flags=re.S)
html=html.replace('<script>\n\'use strict\';','<script id="audit-ui" type="text/plain">\n\'use strict\';')
html=html.replace('원문 PDF·코드·판정 데이터가 이 HTML 안에 포함되어 있습니다.','코드·판정 데이터는 이 HTML에 무손실 압축하여 포함했습니다. 원문 PDF는 같은 폴더의 파일 또는 직접 선택한 파일로 엽니다.')
html=html.replace('원문 PDF, 코드','원문 PDF, 코드')
html=html.replace('<main class="wrap">','''<main class="wrap">
<div class="focus-note" style="margin-bottom:18px"><strong>브라우저용 경량판</strong> · 앱에서 미리보기가 되지 않으면 오른쪽 위 다운로드(↓) 버튼으로 저장한 뒤 Chrome 또는 Edge에서 여세요. ZIP은 먼저 압축을 풀고 <code>DDR5_report.html</code>을 엽니다. 판정 결과는 기존 보고서와 동일합니다.</div>
<div class="focus-note" id="load-status" role="status">보고서 데이터를 불러오는 중입니다… 이 문구가 계속 보이면 다운로드한 HTML을 최신 Chrome 또는 Edge에서 열어 주세요.</div>
<noscript><div class="notice">이 보고서는 탐색·검색에 JavaScript를 사용합니다. 앱 파일 미리보기 대신 다운로드한 HTML을 웹 브라우저에서 열어 주세요.</div></noscript>''')
# Static summary remains visible even if an app preview disallows JS.
html=html.replace('<strong id="overall-score">—</strong>','<strong id="overall-score">7.95%</strong>').replace('<div id="score-fraction"></div>','<div id="score-fraction">204 / 2,567 문장 후보</div>')
boot='''<script>
(async function(){
 const status=document.getElementById('load-status');
 try{
  if(typeof DecompressionStream==='undefined')throw new Error('최신 Chrome·Edge·Firefox·Safari가 필요합니다.');
  const raw=atob(document.getElementById('audit-gzip').textContent.trim());
  const bytes=Uint8Array.from(raw,c=>c.charCodeAt(0));
  const stream=new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  window.__AUDIT_DATA=JSON.parse(await new Response(stream).text());
  const script=document.createElement('script');script.textContent=document.getElementById('audit-ui').textContent;document.body.appendChild(script);
  if(!window.AUDIT?.ready)throw new Error('보고서 스크립트가 실행되지 않았습니다.');
  status.hidden=true;
 }catch(error){status.textContent='보고서를 열지 못했습니다. 이 HTML을 다운로드하여 최신 Chrome 또는 Edge에서 여세요. '+error.message;}
})();
</script>'''
html=html.replace('</body></html>',boot+'</body></html>')
(OUT/'DDR5_report.html').write_text(html)
readme='''DDR5 보고서 여는 방법

1. 이 ZIP 파일을 다운로드하고 전체 압축을 풉니다.
2. DDR5_report.html을 Chrome 또는 Edge로 엽니다.
   Windows: 파일 우클릭 → 연결 프로그램 → Chrome / Edge
   macOS: 파일 우클릭 → 다음으로 열기 → Chrome / Safari
3. JESD79-5B_v1-2.pdf를 HTML과 같은 폴더에 두세요.
4. 보고서에서 원문 PDF가 보이지 않으면 “원문 PDF 선택”을 눌러 동봉 PDF를 선택하세요.

HTML만 다운로드한 경우에도 모든 판정·코드·검색 기능이 동작합니다.
원문 PDF는 사용자가 가진 JESD79-5B_v1-2.pdf를 선택하면 됩니다.

판정 데이터는 원래 보고서와 동일하며 용량을 줄이기 위해 무손실 압축했습니다.
전체 디지털 문장 후보 구현 확인률: 7.95% (204/2,567).
판정 보류 56개 및 PDF 추출 한계가 있어 전 규격의 확정 준수율은 아닙니다.
네트워크 연결이나 별도 프로그램 설치는 필요하지 않습니다.
'''
(OUT/'읽어주세요.txt').write_text(readme,encoding='utf-8-sig')
zipout=ROOT/'deliverables/DDR5_report_browser.zip'
with zipfile.ZipFile(zipout,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for name in ['DDR5_report.html',pdf.name,'읽어주세요.txt']:z.write(OUT/name,'DDR5_report/'+name)
with zipfile.ZipFile(zipout) as z:assert z.testzip() is None
# Prove lossless, byte-for-byte preservation of the entire original audit data.
embedded=re.search(r'<script id="audit-gzip"[^>]*>(.*?)</script>',html,re.S)[1]
assert gzip.decompress(base64.b64decode(embedded))==data
print(json.dumps({'html_bytes':len(html.encode()),'zip_bytes':zipout.stat().st_size,'audit_data_unchanged':True,'html':str(OUT/'DDR5_report.html'),'zip':str(zipout)}))
