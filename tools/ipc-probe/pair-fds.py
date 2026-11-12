import collections,sys,itertools
P={};F=[]
for l in open('fds.tsv',errors='replace'):
    a=l.rstrip('\n').split('\t')
    if a[0]=='P': P[int(a[1])]=(a[2],a[3]=='1')
    elif a[0]=='F': F.append(a)
types=collections.Counter(a[3] for a in F)
print("fd types",types.most_common())
name=lambda p:P.get(p,('?',))[0]
edges=collections.defaultdict(collections.Counter) # (a,b)->kind count
def edge(a,b,k):
    if a!=b: edges[tuple(sorted((a,b)))][k]+=1
# pipes
ph=collections.defaultdict(set)
pipes=[a for a in F if a[3]=='pipe']
for a in pipes: ph[a[4]].add(int(a[1]))
res=0;intra=0;un=0
pairs=set()
for a in pipes:
    peer=a[5]
    if peer in ph:
        res+=1
    else: un+=1
print("pipe fds",len(pipes),"distinct handles",len(ph),"peer resolved",res,"unresolved",un)
# pipe objects: pair handle<->peer
seen=set();cross=0;selfonly=0;multi=0
for a in pipes:
    h,p=a[4],a[5]
    key=tuple(sorted((h,p)))
    if key in seen: continue
    seen.add(key)
    A=ph.get(h,set());B=ph.get(p,set())
    allp=A|B
    if len(allp)==1: selfonly+=1
    else:
        cross+=1
        if len(allp)>2: multi+=1
        for x in A:
            for y in B: edge(x,y,'pipe')
        if not B or not A:
            for x,y in itertools.combinations(sorted(allp),2): edge(x,y,'pipe-shared')
print("pipe objects",len(seen),"within one process",selfonly,"cross-process",cross,"held by >2 procs",multi)
# unix
ux=[a for a in F if a[3]=='unix']
pcb={a[4]:int(a[1]) for a in ux}
pcbs=collections.defaultdict(set)
for a in ux: pcbs[a[4]].add(int(a[1]))
conn=[a for a in ux if a[5]!='0']
r=[a for a in conn if a[5] in pcbs]
print("unix fds",len(ux),"connected",len(conn),"peer resolved",len(r),"unconnected(listen/dgram)",len(ux)-len(conn))
named=collections.Counter()
selfu=0
for a in r:
    for y in pcbs[a[5]]:
        if y==int(a[1]): selfu+=1
        edge(int(a[1]),y,'unix')
print(" unix resolved to same process",selfu)
unres=collections.Counter((a[7] or a[8] or '(unnamed)') for a in conn if a[5] not in pcbs)
print(" unresolved unix by path",unres.most_common(8))
lis=collections.Counter(a[7] for a in ux if a[5]=='0' and a[7])
print(" bound unconnected unix paths",len(lis))
# tcp
tcp=[a for a in F if a[3]=='tcp']
loop=lambda ip: ip.startswith('127.') or ip=='::1' or ip=='::ffff:127.0.0.1'
tl=[a for a in tcp if a[6]!='0' and a[7]!='0' and loop(a[4]) and loop(a[6])]
idx=collections.defaultdict(set)
for a in tcp: idx[(a[5],a[7])].add(int(a[1]))
tr=0
for a in tl:
    peers=idx.get((a[7],a[5]),set())
    if peers: tr+=1
    for y in peers: edge(int(a[1]),y,'tcp')
print("tcp fds",len(tcp),"listening",sum(1 for a in tcp if a[7]=='0'),"loopback connected",len(tl),"peer resolved",tr,"remote connected",sum(1 for a in tcp if a[7]!='0' and not loop(a[6])))
print("udp fds",types['udp'])
# pshm
sh=collections.defaultdict(set)
for a in F:
    if a[3]=='pshm': sh[a[4]].add(int(a[1]))
shared=[(k,v) for k,v in sh.items() if len(v)>1]
print("pshm names",len(sh),"shared by >1 proc",len(shared),[(k,len(v)) for k,v in shared][:8])
for k,v in shared:
    if len(v)<=8:
        for x,y in itertools.combinations(sorted(v),2): edge(x,y,'shm')
print("fifo",[(a[1],a[4]) for a in F if a[3]=='fifo'][:5])
print("kctl",collections.Counter(a[4] for a in F if a[3]=='kctl').most_common(6))
# graph
deg=collections.Counter()
for (a,b) in edges: deg[a]+=1;deg[b]+=1
print("EDGES distinct pid pairs",len(edges),"procs with >=1 edge",len(deg),"of readable",sum(1 for p in P.values() if p[1]),"total",len(P))
kinds=collections.Counter()
for e,c in edges.items():
    for k in c: kinds[k]+=1
print("edges by kind",kinds)
print("top degree",[(name(p),p,d) for p,d in deg.most_common(12)])
ds=sorted(deg.values())
print("degree median",ds[len(ds)//2],"p90",ds[int(len(ds)*.9)],"deg1",sum(1 for d in ds if d==1),"deg<=3",sum(1 for d in ds if d<=3))
# components
par={}
def f(x):
    while par.setdefault(x,x)!=x:
        par[x]=par[par[x]];x=par[x]
    return x
for a,b in edges: par[f(a)]=f(b)
comp=collections.Counter(f(x) for x in deg)
print("components",len(comp),"sizes",sorted(comp.values(),reverse=True)[:10])
import pickle;pickle.dump((dict(edges),P),open('edges.pkl','wb'))
