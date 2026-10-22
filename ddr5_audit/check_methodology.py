from pathlib import Path
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from functools import partial
from threading import Thread
from playwright.sync_api import sync_playwright
import json,csv
R=Path(__file__).resolve().parent
P=R/'deliverables/DDR5_methodology_explained.html'
class Quiet(SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
server=ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=str(P.parent)))
Thread(target=server.serve_forever,daemon=True).start()
with sync_playwright() as w:
 browser=w.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
 page=browser.new_page(viewport={'width':1400,'height':1000});errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
 page.goto(f'http://127.0.0.1:{server.server_port}/{P.name}',wait_until='load')
 page.wait_for_function('window.METHOD_REPORT && METHOD_REPORT.ready')
 assert page.locator('#q1 details.step').count()==8
 assert page.evaluate('METHOD_REPORT.data.records.length')==3507
 assert page.evaluate('Object.values(METHOD_REPORT.data.counts).reduce((a,b)=>a+b,0)')==3507
 assert page.evaluate('METHOD_REPORT.data.trace.ordered_rule_checks.length')==6
 assert page.evaluate('METHOD_REPORT.data.trace.ordered_rule_checks[5].text_match') is True
 page.screenshot(path=str(R/'validation/methodology-desktop.png'))
 page.evaluate("jumpRecord('P048-010')")
 assert 'statement-rule' in page.locator('#r-P048-010').inner_text()
 assert '초기 상태가 U가 아님' in page.locator('#r-P048-010').inner_text()
 page.locator('#r-P048-010 .refs button').first.click();page.wait_for_selector('#viewer[open] .hit')
 assert page.locator('#viewer .hit').count()>0
 page.get_by_role('button',name='닫기',exact=True).click()
 page.evaluate("jumpRecord('P235-004')")
 assert '정정 대상' in page.locator('#r-P235-004').inner_text()
 page.evaluate('resetFilters()');page.locator('#chapter').select_option('4');page.locator('#status').select_option('N')
 assert page.evaluate('METHOD_REPORT.state.rows.every(r=>r.chapter==="4"&&r.status==="N")')
 page.locator('#demo-mr').select_option('normal');page.locator('#demo-crc').select_option('1')
 assert 'BL18' in page.locator('#demo-result').inner_text()
 page.locator('#demo-mr').select_option('31')
 assert '선행 조건에 어긋납니다' in page.locator('#demo-result').inner_text()
 with page.expect_download() as event:page.evaluate('downloadCSV()')
 event.value.save_as(str(R/'validation/methodology-browser-export.csv'))
 with (R/'validation/methodology-browser-export.csv').open(encoding='utf-8-sig') as f:rows=list(csv.DictReader(f))
 assert len(rows)==3507
 r=next(x for x in rows if x['id']=='P048-010');assert r['first_rule']=='command burst length 16 regardless' and r['final_status']=='F'
 assert next(x for x in rows if x['id']=='P235-004')['known_erratum']
 page.set_viewport_size({'width':390,'height':844});page.evaluate('window.scrollTo(0,0)')
 assert page.evaluate('document.documentElement.scrollWidth<=innerWidth+2')
 page.screenshot(path=str(R/'validation/methodology-mobile.png'))
 assert not errors,errors
 browser.close()
server.shutdown()
result={'html_load':True,'eight_steps':True,'six_rule_checks':True,'sentence_routes':3507,'chapter_status_filters':True,'source_viewer':True,'crc_context_demo':True,'erratum_displayed':True,'csv_export':True,'mobile_layout':True,'page_errors':errors}
(R/'validation/methodology-ui-checks.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
