from pathlib import Path
import concurrent.futures,json,subprocess,time,sys
ROOT=Path(__file__).parent
SRC=ROOT/'source/rmc-ddr5-main/verif/ddr5_model'
OUT=ROOT/'validation';OUT.mkdir(exist_ok=True)
V=[str(ROOT/'tools/bin/python') if (ROOT/'tools/bin/python').exists() else sys.executable,'-m','verilator']
tops=['tb_ecc','tb_ddr5_smoke','tb_ddr5_refresh','tb_ddr5_ecc','tb_ddr5_training']
def run(top):
    out=OUT/top;out.mkdir(exist_ok=True)
    sources=['rtl/ddr5_pkg.sv','rtl/ddr5_timing_pkg.sv','rtl/ddr5_ecc_pkg.sv','rtl/ddr5_device.sv',f'tb/{top}.sv']
    command=V+['--binary','--timing','-j','2','-CFLAGS','-std=c++20','-MAKEFLAGS','CFG_CXXFLAGS_PCH_I=-include','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNOPTFLAT','-Wno-fatal','--top-module',top,'-o',f'sim_{top}','-Mdir',str(out/'obj')]+sources
    t=time.time()
    with (out/'build.log').open('w') as f:
        p=subprocess.run(command,cwd=SRC,stdout=f,stderr=subprocess.STDOUT,timeout=600)
    r=dict(top=top,build_exit=p.returncode,command=command,cwd=str(SRC))
    if p.returncode==0:
        with (out/'run.log').open('w') as f:
            try:
                q=subprocess.run([str(out/'obj'/f'sim_{top}')],cwd=out,stdout=f,stderr=subprocess.STDOUT,timeout=90)
                r['run_exit']=q.returncode
            except subprocess.TimeoutExpired:r['run_exit']='timeout'
        r['output']=(out/'run.log').read_text()
    else:r['output']=(out/'build.log').read_text()[-5000:]
    r['seconds']=round(time.time()-t,2)
    (out/'result.json').write_text(json.dumps(r,ensure_ascii=False,indent=2))
    print(top,'build',r['build_exit'],'run',r.get('run_exit'),'seconds',r['seconds'],flush=True)
    return r
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    rs=list(pool.map(run,tops))
(OUT/'results.json').write_text(json.dumps(rs,ensure_ascii=False,indent=2))
