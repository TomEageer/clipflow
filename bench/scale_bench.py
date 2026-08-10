#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""百万条规模压测：索引体积、写入吞吐、检索延迟是否随规模劣化"""
import sqlite3, os, time, random, json, tempfile, statistics, gc

random.seed(7)
WORK = tempfile.mkdtemp(prefix="clipflow_scale_")
CN = "订单支付回调幂等分布式锁供应商出票候补抢票退款结算网关配置中心索引优化事务隔离级别缓存穿透雪崩熔断降级限流线程池阻塞队列消息投递重试补偿对账库存超卖预扣减"
EN = "order payment callback idempotent distributed lock supplier ticket refund gateway config index transaction cache circuit breaker thread pool retry"

def cn(n): return "".join(random.choice(CN) for _ in range(n))
def make(i):
    k = i % 5
    if k == 0: return f"关于{cn(12)}的处理说明：{cn(60)}。详见 trackID trace-2026{i:06d}。"
    if k == 1: return (f"public void handlePay{i}(PayNotifyVO vo) {{\n    if (!DistributedLock.lock(K+vo.getOrderId(),30)) return;\n"
                       f"    try {{ payService.process(vo); }} finally {{ DistributedLock.unlock(K); }}\n}}")
    if k == 2: return (f"select o.OrderID,o.TradeNo,e.PlatformId from OrderRecord{i%12+1:02d} o "
                       f"left join OrderDetail e on e.OrderID=o.OrderID where o.CreateTime>'2026-08-01' limit 200;")
    if k == 3: return json.dumps({"orderId": f"2606{i:08d}", "amount": round(random.uniform(10,2000),2),
                                  "status": random.choice(["PAID","SEIZED","FAILED"]), "备注": cn(20)}, ensure_ascii=False)
    return f"{random.choice(EN.split())} {cn(30)} https://api.internal.example.com/v1/task/{i}"

def bigram(s):
    out, buf = [], []
    def flush():
        nonlocal buf
        if len(buf) == 1: out.append(buf[0])
        elif len(buf) > 1: out.extend("".join(buf[i:i+2]) for i in range(len(buf)-1))
        buf = []
    for ch in s:
        if '一' <= ch <= '鿿': buf.append(ch)
        else: flush(); out.append(ch)
    flush(); return " ".join(out)

def size(p): return sum(os.path.getsize(p+s) for s in ("","-wal","-shm") if os.path.exists(p+s))

p = os.path.join(WORK, "scale.sqlite")
c = sqlite3.connect(p)
c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA synchronous=NORMAL")
c.execute("PRAGMA auto_vacuum=INCREMENTAL"); c.execute("PRAGMA cache_size=-20000")
c.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, body TEXT NOT NULL, created INTEGER NOT NULL, app TEXT, kind INTEGER)")
c.execute("CREATE INDEX idx_created ON items(created DESC)")
c.execute("CREATE INDEX idx_app ON items(app, created DESC)")
c.execute("CREATE VIRTUAL TABLE fts USING fts5(tok, content='', detail=full)")

QUERIES = ["幂等","订单","DistributedLock","PlatformId","SEIZED","超卖","分布式","payService","OrderDetail"]
APPS = ["com.jetbrains.intellij","com.google.Chrome","com.apple.Terminal","com.electron.lark","com.apple.Safari"]

def probe(n_rows):
    lats, hits = [], []
    for q in QUERIES:
        toks = bigram(q).split(); expr = '"' + " ".join(toks) + '"'
        ts = []
        for _ in range(5):
            t0 = time.perf_counter()
            r = c.execute("SELECT i.id,substr(i.body,1,80) FROM fts JOIN items i ON i.id=fts.rowid "
                          "WHERE fts MATCH ? ORDER BY fts.rowid DESC LIMIT 20", (expr,)).fetchall()
            ts.append((time.perf_counter()-t0)*1000)
        lats.append(statistics.median(ts))
        hits.append(c.execute("SELECT count(*) FROM fts WHERE fts MATCH ?", (expr,)).fetchone()[0])
    # 带过滤的复合查询（真实场景：搜索 + 限来源 App）
    t0 = time.perf_counter()
    c.execute("SELECT i.id FROM fts JOIN items i ON i.id=fts.rowid WHERE fts MATCH ? AND i.app=? "
              "ORDER BY fts.rowid DESC LIMIT 20", ('"幂 幂等 等"'.replace('幂 幂等 等', bigram("幂等")), APPS[0])).fetchall()
    filt = (time.perf_counter()-t0)*1000
    # 纯浏览（无搜索，最高频操作）
    t0 = time.perf_counter()
    c.execute("SELECT id,substr(body,1,80) FROM items ORDER BY created DESC LIMIT 20").fetchall()
    browse = (time.perf_counter()-t0)*1000
    return statistics.median(lats), max(lats), max(hits), filt, browse

print(f"{'规模':>10s} {'原始文本':>10s} {'库+索引':>10s} {'膨胀':>6s} {'写入':>12s} "
      f"{'检索中位':>9s} {'检索最差':>9s} {'最大命中':>9s} {'带过滤':>8s} {'纯浏览':>8s}")
BATCH = 100_000
raw = 0
for step in range(1, 11):                       # 10 × 10万 = 100万
    rows, ftsr = [], []
    base_id = (step-1)*BATCH
    for j in range(BATCH):
        i = base_id + j
        b = make(i); raw += len(b.encode())
        rows.append((i, b, 1754800000+i, random.choice(APPS), i % 5))
        ftsr.append((i, bigram(b)))
    t0 = time.perf_counter()
    c.executemany("INSERT INTO items VALUES(?,?,?,?,?)", rows)
    c.executemany("INSERT INTO fts(rowid,tok) VALUES(?,?)", ftsr)
    c.commit()
    wt = time.perf_counter()-t0
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    total = size(p); n = step*BATCH
    med, mx, mh, filt, browse = probe(n)
    print(f"{n:10,} {raw/1048576:9.1f}M {total/1048576:9.1f}M {total/raw:5.2f}x "
          f"{BATCH/wt:9,.0f}条/s {med:8.2f}ms {mx:8.2f}ms {mh:9,} {filt:7.2f}ms {browse:7.2f}ms")
    del rows, ftsr; gc.collect()

print(f"\n库文件：{size(p)/1048576:.1f} MB @ 100万条")
print("optimize 前后对比：")
t0=time.perf_counter(); c.execute("INSERT INTO fts(fts) VALUES('optimize')"); c.commit(); ot=time.perf_counter()-t0
c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
print(f"  FTS optimize 耗时 {ot:.1f}s → 库 {size(p)/1048576:.1f} MB")
med,mx,mh,filt,browse = probe(1_000_000)
print(f"  optimize 后检索 中位 {med:.2f}ms / 最差 {mx:.2f}ms / 带过滤 {filt:.2f}ms / 纯浏览 {browse:.2f}ms")
print(f"\n{WORK}")
