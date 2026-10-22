from pathlib import Path
from playwright.sync_api import sync_playwright
import json
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from threading import Thread
from functools import partial
root=Path(__file__).resolve().parent
report=root/'deliverables/JESD79-5B_ddr5_sentence_audit.html'
handler=partial(SimpleHTTPRequestHandler,directory=str(report.parent))
server=ThreadingHTTPServer(('127.0.0.1',0),handler)
Thread(target=server.serve_forever,daemon=True).start()
with sync_playwright() as p:
 browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
 page=browser.new_page(viewport={'width':1480,'height':1080},device_scale_factor=1)
 errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
 page.goto(f'http://127.0.0.1:{server.server_port}/{report.name}',wait_until='load',timeout=90000)
 page.wait_for_function('window.AUDIT && window.AUDIT.ready')
 assert page.locator('#overall-score').inner_text()=='7.95%'
 assert page.evaluate('AUDIT.denominator')==2567
 assert page.evaluate('AUDIT.data.units.length')==13985
 assert page.evaluate('AUDIT.data.pages.length')==502
 page.screenshot(path=str(root/'validation/report-desktop.png'),full_page=False)
 # Navigate chapter, clause, status, and body expansion.
 page.evaluate("selectChapter('4',true)")
 page.locator('#section').select_option('4.17.2')
 assert page.evaluate('AUDIT.state.rows.every(u=>u.section.startsWith("4.17.2"))')
 page.locator('#status').select_option('X')
 assert page.evaluate('AUDIT.state.rows.length')>0
 page.locator('details.record').first.locator('summary').click()
 page.wait_for_selector('.record[open] .evidence')
 assert page.locator('.record[open] .reason').inner_text()
 page.locator('.record[open] .evidence button').first.click()
 page.wait_for_selector('#viewer[open] .code-line.hit')
 assert page.locator('#viewer .code-line.hit').count()>0
 page.locator('#viewer button[aria-label="창 닫기"]').click()
 # Direct ID and page text cross-reference.
 page.evaluate("gotoItem('P048-003')")
 assert page.locator('#item-P048-003').get_attribute('open') is not None
 page.evaluate("showPageText(48,'P048-003')")
 assert 'Mode Register Read' in page.locator('#viewer-body').inner_text()
 page.locator('#viewer button[aria-label="창 닫기"]').click()
 # Embedded PDF round-trip, browser iframe source and byte hash.
 page.evaluate('openPdf(48)')
 assert '#page=48' in page.locator('.pdf-frame').get_attribute('src')
 assert page.evaluate("atob(document.getElementById('pdfdata').textContent.trim()).slice(0,5)")=='%PDF-'
 page.locator('#viewer button[aria-label="창 닫기"]').click()
 # CSV download has every sentence, including exclusions.
 with page.expect_download() as dl:page.evaluate('exportCSV()')
 download=dl.value;download.save_as(str(root/'validation/browser-export.csv'))
 import csv
 with (root/'validation/browser-export.csv').open(encoding='utf-8-sig') as f:rows=list(csv.DictReader(f))
 assert len(rows)==3507,len(rows)
 assert len({r['id'] for r in rows})==len(rows)
 # Table row context and page-independent search.
 page.evaluate("resetFilters();document.getElementById('kind').value='table';document.getElementById('search').value='MR0';applyFilters()")
 assert page.evaluate('AUDIT.state.rows.length')>0
 page.locator('details.record').first.locator('summary').click()
 page.wait_for_selector('.record[open] .context-table')
 # Small-screen controls remain within viewport.
 page.set_viewport_size({'width':390,'height':844});page.evaluate('window.scrollTo(0,0)')
 page.screenshot(path=str(root/'validation/report-mobile.png'),full_page=False)
 overflow=page.evaluate('document.documentElement.scrollWidth>innerWidth+2')
 assert not overflow,'mobile horizontal overflow'
 assert not errors,errors
 browser.close()
 result={'html_load':True,'overall_rate':'7.95%','digital_sentences':2567,'sentence_candidates':len(rows),'units':13985,'chapters_and_sections':True,'status_filter':True,'code_reference_viewer':True,'page_text_viewer':True,'embedded_pdf':True,'csv_export':True,'table_context':True,'mobile_layout':True,'page_errors':errors}
 (root/'validation/report-ui-checks.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
 print(json.dumps(result,ensure_ascii=False))
