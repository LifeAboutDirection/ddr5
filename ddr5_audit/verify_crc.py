"""Independent equation check, using the actual eight PDF XOR equations.
The DUT's shift algorithm is translated literally, not treated as a new oracle.
This proves the 64-bit -> 8-bit linear map only, not its DQ mapping/frame.
"""
from pathlib import Path
import re,json,functools,operator
ROOT=Path(__file__).resolve().parent
D=json.loads((ROOT/'extracted.json').read_text())
s=' '.join(u['text'] for u in D['units'] if (u['page']==318 and 'NewCRC[' in u['text']) or (u['page']==319 and 'NewCRC[' in u['text']))
equations={int(n):[int(b) for b in re.findall(r'D\[(\d+)\]',expr)] for n,expr in re.findall(r'NewCRC\[(\d)\]\s*=\s*([^;]+);',s)}
assert set(equations)==set(range(8))
source=(ROOT/'source/rmc-ddr5-main/verif/ddr5_model/rtl/ddr5_ecc_pkg.sv').read_text()
assert "c ^= 8'h07" in source and 'for (int i = 63; i >= 0; i--)' in source

def spec(d):
 return sum(functools.reduce(operator.xor,[(d>>b)&1 for b in eq],0)<<n for n,eq in equations.items())
def model(d):
 c=0
 for i in range(63,-1,-1):
  top=(c>>7)&1;c=(c<<1)&255
  if top^((d>>i)&1):c^=7
 return c
vectors=[0]+[1<<i for i in range(64)]
passed=sum(spec(d)==model(d) for d in vectors)
r=dict(test='CRC8_D64 standard XOR equations vs source shift algorithm',checks=len(vectors),passed=passed,basis_complete=True,method='zero vector and 64 basis vectors; both maps linear over GF(2)',formula_terms={str(k):len(v) for k,v in equations.items()})
assert passed==65
(ROOT/'validation/crc_equations.json').write_text(json.dumps(r,indent=2))
print(json.dumps(r))
