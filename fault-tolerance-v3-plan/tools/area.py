import sys, re
rows=[]; pend=None
for line in open(sys.argv[1]):
    t=line.rstrip('\n')
    if not t.strip() or t.startswith(('-','*','Report','Design','Version','Date','Library','Hier','  ','Number','Combi','Buf','Noncombi','Macro','Net','Total')) and not re.match(r'^\s+\d',t):
        if re.match(r'^\S', t) and len(t.split())==1: pend=t.split()[0]
        continue
    f=t.split()
    nums=[x for x in f if re.match(r'^-?\d+(\.\d+)?$',x)]
    if len(f)==1: pend=f[0]; continue
    if re.match(r'^\s',t) and pend: name=pend; vals=f
    else: name=f[0]; vals=f[1:]
    pend=None
    try: tot,pct,cb,nc,bb=map(float,vals[:5]); rows.append((name,tot,pct,cb,nc,bb,vals[5] if len(vals)>5 else ''))
    except: pass
import json; json.dump(rows,open(sys.argv[2],'w'))
print(len(rows))
