#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定位 FTS5 尾延迟来源：高频词 + ORDER BY rank 是不是元凶"""
import sqlite3, os, time, random, json, tempfile, statistics
random.seed(42)
WORK = tempfile.mkdtemp(prefix="clipflow_lat_")
CN = "订单支付回调幂等分布式锁供应商出票候补抢票退款结算网关配置中心索引优化事务隔离级别缓存穿透雪崩熔断降级限流线程池阻塞队列消息投递重试补偿对账"
EN = "order payment callback idempotent distributed lock supplier ticket refund gateway config index transaction cache circuit breaker thread pool retry"
def cn_text(n): return "".join(random.choice(CN) for _ in range(n))
def make_item(i):
    k=i%5
    if k==0: return f"关于{cn_text(12)}的处理说明：{cn_text(60)}。详见 trackID trace-2026{i:06d}。"
    if k==1: return (f"public void handlePay{i}(PayNotifyVO vo) {{\n    if (!DistributedLock.lock(LOCK_KEY + vo.getOrderId(), 30)) {{ return; }}\n"
                     f"    try {{ payService.process(vo); }} finally {{ DistributedLock.unlock(...); }}\n}}")
    if k==2: return (f"select o.OrderID, o.TradeNo, e.PlatformId from OrderRecord{i%12+1:02d} o "
                     f"left join OrderDetail e on e.OrderID=o.OrderID where o.CreateTime>'2026-08-01' limit 200;")
    if k==3: return json.dumps({"orderId":f"2606{i:08d}","amount":round(random.uniform(10,2000),2),
                                "status":random.choice(["PAID","SEIZED","FAILED"]),"备注":cn_text(20)}, ensure_ascii=False)
    return f"{random.choice(EN.split())} {cn_text(30)} https://api.internal.example.com/v1/task/{i}"
def bigram(s):
    out,buf=[],[]
    def flush():
        nonlocal buf
        if len(buf)==1: out.append(buf[0])
        elif len(buf)>1: out.extend("".join(buf[i:i+2]) for i in range(len(buf)-1))
        buf=[]
    for ch in s:
        if '一'<=ch<='鿿': buf.append(ch)
        else: flush(); out.append(ch)
    flush(); return " ".join(out)

N=100_000
ITEMS=[make_item(i) for i in range(N)]
p=os.path.join(WORK,"t.sqlite")
c=sqlite3.connect(p); c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, body TEXT, created INTEGER)")
c.executemany("INSERT INTO items VALUES(?,?,?)", [(i,ITEMS[i],1754800000+i) for i in range(N)])
c.execute("CREATE VIRTUAL TABLE fts USING fts5(tok, content='', detail=full)")
c.executemany("INSERT INTO fts(rowid,tok) VALUES(?,?)", [(i,bigram(ITEMS[i])) for i in range(N)])
c.commit(); c.execute("PRAGMA wal_checkpoint(TRUNCATE)")

def timeit(sql, args, reps=7):
    ts=[]
    for _ in range(reps):
        t0=time.perf_counter(); r=c.execute(sql,args).fetchall(); ts.append((time.perf_counter()-t0)*1000)
    return statistics.median(ts), max(ts), len(r)

print(f"{'查询':16s} {'命中总数':>9s}  {'ORDER BY rank':>16s}  {'ORDER BY id DESC':>18s}  {'无排序':>12s}")
for q in ["订单支付","幂等","抢票退款","分布式锁","DistributedLock","PlatformId","SEIZED","订单","支付"]:
    toks=bigram(q).split(); expr='"'+" ".join(toks)+'"'
    n=c.execute("SELECT count(*) FROM fts WHERE fts MATCH ?",(expr,)).fetchone()[0]
    a=timeit("SELECT i.id FROM fts JOIN items i ON i.id=fts.rowid WHERE fts MATCH ? ORDER BY rank LIMIT 20",(expr,))
    b=timeit("SELECT i.id FROM fts JOIN items i ON i.id=fts.rowid WHERE fts MATCH ? ORDER BY fts.rowid DESC LIMIT 20",(expr,))
    d=timeit("SELECT i.id FROM fts JOIN items i ON i.id=fts.rowid WHERE fts MATCH ? LIMIT 20",(expr,))
    print(f"{q:16s} {n:9,}  {a[0]:7.2f}/{a[1]:6.2f}ms  {b[0]:8.2f}/{b[1]:7.2f}ms  {d[0]:5.2f}/{d[1]:5.2f}ms")

print("\n结论验证：命中数越多 → ORDER BY rank 越慢（必须给所有命中打分）")
print("对剪贴板场景，用户要的是「最近的」不是「最相关的」→ ORDER BY rowid DESC 才对")
print(f"\n{WORK}")
