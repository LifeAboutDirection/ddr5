from pathlib import Path
import hashlib,zipfile,json,sys,importlib.metadata
ROOT=Path(__file__).resolve().parent
files=[]
for name in ['README_ko.md','extracted.json','audited.json','extract_standard.py','audit_rules.py','review_pass2.py','finalize_audit.py','build_report.py','report_template.html','run_tests.py','run_independent.py','verify_crc.py','tb_audit.sv','check_report.py','package_report.py']:
 files.append(ROOT/name)
files.extend((ROOT/'deliverables').glob('*.html'))
files.extend((ROOT/'deliverables').glob('*.json'))
files.extend((ROOT/'deliverables').glob('*.csv'))
for name in ['ddr5_device.sv','ddr5_pkg.sv','ddr5_timing_pkg.sv','ddr5_ecc_pkg.sv']:
 files.append(ROOT/'source/rmc-ddr5-main/verif/ddr5_model/rtl'/name)
for name in ['tb_ecc','tb_ddr5_smoke','tb_ddr5_refresh','tb_ddr5_ecc','tb_ddr5_training']:
 files.append(ROOT/'source/rmc-ddr5-main/verif/ddr5_model/tb'/f'{name}.sv')
 for item in ['build.log','run.log','result.json']:files.append(ROOT/'validation'/name/item)
for name in ['results.json','audit_build.log','audit_run.log','x4_lint.log','crc_equations.json','independent-result.json','report-ui-checks.json','data-integrity.json','report-desktop.png','report-mobile.png']:
 files.append(ROOT/'validation'/name)
env={'python':sys.version,'pymupdf':importlib.metadata.version('PyMuPDF'),'playwright':importlib.metadata.version('playwright'),'verilator_distribution':'5.48.0','verilator_runtime_report':'5.49'}
(ROOT/'validation/environment.json').write_text(json.dumps(env,indent=2));files.append(ROOT/'validation/environment.json')
files=sorted(set(files));assert all(f.is_file() for f in files)
manifest=''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+str(f.relative_to(ROOT))+'\n' for f in files)
(ROOT/'MANIFEST.sha256').write_text(manifest);files.append(ROOT/'MANIFEST.sha256')
out=ROOT/'deliverables/JESD79-5B_audit_evidence.zip'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for f in files:z.write(f,'ddr5_sentence_audit/'+str(f.relative_to(ROOT)))
with zipfile.ZipFile(out) as z:
 assert z.testzip() is None
 for line in manifest.splitlines():
  sha,name=line.split('  ',1)
  assert hashlib.sha256(z.read('ddr5_sentence_audit/'+name)).hexdigest()==sha
print(json.dumps({'zip_bytes':out.stat().st_size,'files':len(files),'manifest_verified':True,'path':str(out)}))
