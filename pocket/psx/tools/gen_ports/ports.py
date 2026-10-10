# Run from this directory after ports.py: python3 ports.py && python3 gen_stub.py && python3 gen_inst.py && python3 gen_flat.py
# ports.py reads the entity of rtl/psx_top_pocket.vhd; gen_stub.py writes psx_top_stub.v, gen_flat.py psx_top_pocket_flat.vhd,
# gen_inst.py the stub instance and glue wiring that core_top.v carries (copy the output by hand).
import re,json,sys
lines=open(str(__import__('pathlib').Path(__file__).resolve().parents[4] / 'rtl' / 'psx_top_pocket.vhd')).read().split('\n')
b=[i for i,l in enumerate(lines) if re.match(r'\s*entity\s+psx_top_pocket\s+is\b',l,re.I)]
e=[i for i,l in enumerate(lines) if re.match(r'\s*end\s+entity\b',l,re.I)]
p=[i for i,l in enumerate(lines) if b and i>b[0] and re.match(r'\s*port\b',l,re.I)]
if not (b and p and [i for i in e if i>p[0]]): sys.exit('ports.py: entity psx_top_pocket / port / end entity not found in rtl/psx_top_pocket.vhd')
src=lines[p[0]+1:[i for i in e if i>p[0]][0]]
ports=[]
for l in src:
    l=l.split('--')[0].strip()
    m=re.match(r'(\w+)\s*:\s*(in|out|buffer)\s+(.*?)\s*(:=.*)?;?$',l)
    if not m: continue
    n,d,t=m.group(1),m.group(2),m.group(3).rstrip(';').strip()
    t=re.sub(r':=.*','',t).strip()
    w=1
    mm=re.search(r'\(\s*(\d+)\s+downto\s+(\d+)\s*\)',t)
    if mm: w=int(mm.group(1))-int(mm.group(2))+1
    if t.startswith('joypad_t'): w=60
    if t.startswith('integer'): w=2
    ports.append((n,'input' if d=='in' else 'output',w))
json.dump(ports,open('ports.json','w'))
import re as _r
raw=[]
for l in src:
    l=l.split('--')[0].strip().replace('\t',' ')
    m=_r.match(r'(\w+)\s*:\s*(in|out|buffer)\s+(.*?)\s*(:=.*)?;?$',l)
    if m: raw.append((m.group(1),m.group(2),_r.sub(r':=.*','',m.group(3)).rstrip(';').strip()))
json.dump(raw,open('ports_t.json','w'))
print(len(ports),sum(w for n,d,w in ports if d=='input'),sum(w for n,d,w in ports if d=='output'))
