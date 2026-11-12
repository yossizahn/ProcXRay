import json,collections,itertools,pickle
d=json.load(open('all.json')); ps=d['processes']
pname={p['pid']:p['name'] for p in ps}
allp=[l.split(None,2) for l in open('ps.txt')]
print("ps",len(allp),"lsmp",len(ps),"missing",[(a[0],a[2].strip().split('/')[-1]) for a in allp if int(a[0]) not in pname][:12])
print("empty port lists",sum(1 for p in ps if not p['ports']))
# shapes with extra keys
shapes=collections.Counter()
for p in ps:
    for q in p['ports']:
        for k in q:
            shapes[k]+=1
print(shapes)
recv={} ; send=collections.defaultdict(set); dup=0
def walk(pid,q,inset=False):
    global dup
    r=q.get('rights',[])
    o=q.get('ipc-object')
    if 'recv' in r:
        if o in recv and recv[o]!=pid: dup+=1
        recv[o]=pid
    if 'send' in r or 'send once' in r:
        send[o].add((pid,q.get('type'),q.get('pid')))
    for m in q.get('members',[]): walk(pid,m,True)
for p in ps:
    for q in p['ports']: walk(p['pid'],q)
print("recv objects",len(recv),"collisions",dup,"send objects",len(send))
# resolve send rights
tot=0;res=0;selfs=0;kobj=collections.Counter();unres=collections.Counter();agree=0;dis=0
edges=collections.Counter()
for o,hs in send.items():
    for pid,t,rp in hs:
        tot+=1
        if o in recv:
            res+=1
            if recv[o]==pid: selfs+=1
            else: edges[(pid,recv[o])]+=1
            if rp is not None:
                if rp==recv[o]: agree+=1
                else: dis+=1
        else:
            unres[(t, rp if rp in(None,-1) else 'pid')]+=1
print("send/sonce rights",tot,"resolved by ipc-object join",res,"to self",selfs,"lsmp pid agrees",agree,"disagrees",dis)
print("unresolved by type",unres.most_common(30))
print("directed links",len(edges),"undirected",len({tuple(sorted(e)) for e in edges}),"channels",sum(edges.values()))
ind=collections.Counter();outd=collections.Counter()
for (a,b) in edges: outd[a]+=1; ind[b]+=1
n=len(ps)
print("top servers (in-degree)",[(pname.get(p,p),c,round(100*c/n)) for p,c in ind.most_common(25)])
for th in (0.5,0.25,0.1,0.05):
    hubs={p for p,c in ind.items() if c>=th*n}
    rest=[e for e in edges if e[1] not in hubs and e[0] not in hubs]
    od=collections.Counter(); 
    for a,b in rest: od[a]+=1; od[b]+=1
    v=sorted(od.values()) or [0]
    print("hub>=%d%%: hubs %d, links left %d, procs with links %d, peers median %d p90 %d max %d"%(th*100,len(hubs),len(rest),len(od),v[len(v)//2],v[int(len(v)*.9)],v[-1]))
od=sorted(outd.values()); print("out-degree median",od[len(od)//2],"p90",od[int(len(od)*.9)],"max",od[-1],"procs with no out",n-len(outd))
tp=collections.Counter()
for p in ps: tp[p['pid']]=len(p['ports'])
v=sorted(tp.values()); print("ports per proc median",v[len(v)//2],"p90",v[int(len(v)*.9)],"max",[(pname[p],c) for p,c in tp.most_common(4)])
qd=[(q['msg_count'],pname[p['pid']]) for p in ps for q in p['ports'] if q.get('msg_count')]
print("recv ports with queued msgs",len(qd),sorted(qd,reverse=True)[:5])
# task control ports to other processes
tc=collections.Counter()
for p in ps:
    for q in p['ports']:
        if q.get('type') in('TASK-CONTROL','TASK-READ','TASK-NAME') and q.get('pid') not in (None,p['pid']): tc[q['type']]+=1
print("task ports for other procs",tc)
iok=collections.Counter(q['description'].split('(')[0] for p in ps for q in p['ports'] if q.get('type')=='IOKIT-CONNECT' and 'description' in q)
print("iokit-connect",sum(iok.values()),iok.most_common(6))
pickle.dump((dict(edges),pname),open('medges.pkl','wb'))
