"""Run the independent DUT counterexamples and x4 elaboration check.
The simulation process exits zero intentionally; inspect SPEC_FAIL records.
"""
from pathlib import Path
import subprocess,sys,json
ROOT=Path(__file__).resolve().parent
SRC=ROOT/'source/rmc-ddr5-main/verif/ddr5_model'
OUT=ROOT/'validation';OUT.mkdir(exist_ok=True)
V=[str(ROOT/'tools/bin/python') if (ROOT/'tools/bin/python').exists() else sys.executable,'-m','verilator']
src=['rtl/ddr5_pkg.sv','rtl/ddr5_timing_pkg.sv','rtl/ddr5_ecc_pkg.sv','rtl/ddr5_device.sv']
command=V+['--binary','--timing','-j','2','-CFLAGS','-std=c++20','-MAKEFLAGS','CFG_CXXFLAGS_PCH_I=-include','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNOPTFLAT','-Wno-fatal','--top-module','tb_audit','-o','sim_tb_audit','-Mdir',str(OUT/'audit_obj')]+src+[str(ROOT/'tb_audit.sv')]
with (OUT/'audit_build.log').open('w') as f:
 p=subprocess.run(command,cwd=SRC,stdout=f,stderr=subprocess.STDOUT,timeout=600)
assert p.returncode==0,'Inspect audit_build.log'
with (OUT/'audit_run.log').open('w') as f:
 q=subprocess.run([str(OUT/'audit_obj/sim_tb_audit')],cwd=OUT,stdout=f,stderr=subprocess.STDOUT,timeout=90)
log=(OUT/'audit_run.log').read_text();lines=[l for l in log.splitlines() if l.startswith('AUDIT|')]
x4cmd=V+['--lint-only','--timing','-Wno-fatal','--top-module','ddr5_device','-GDQ_BITS=4']+src
with (OUT/'x4_lint.log').open('w') as f:
 x=subprocess.run(x4cmd,cwd=SRC,stdout=f,stderr=subprocess.STDOUT,timeout=120)
r=dict(build_exit=p.returncode,run_exit=q.returncode,checks=len(lines),spec_failures=sum('|SPEC_FAIL|' in l for l in lines),x4_exit=x.returncode,command=command,x4_command=x4cmd)
(OUT/'independent-result.json').write_text(json.dumps(r,indent=2))
print(json.dumps(r))
