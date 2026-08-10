#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Clipflow 存储 & 检索实验 v2（修正测量法：每步 checkpoint 后量体积）"""
import sqlite3, os, time, random, zlib, json, tempfile, statistics

random.seed(42)
WORK = tempfile.mkdtemp(prefix="clipflow_bench2_")
CN = "订单支付回调幂等分布式锁供应商出票候补抢票退款结算网关配置中心索引优化事务隔离级别缓存穿透雪崩熔断降级限流线程池阻塞队列消息投递重试补偿对账"
EN = "order payment callback idempotent distributed lock supplier ticket refund gateway config index transaction cache circuit breaker thread pool retry"

def cn_text(n): return "".join(random.choice(CN) for _ in range(n))

def make_item(i):
    k = i % 5
    if k == 0: return f"关于{cn_text(12)}的处理说明：{cn_text(60)}。详见 trackID trace-2026{i:06d}。"
    if k == 1: return (f"public void handlePay{i}(PayNotifyVO vo) {{\n"
                       f"    if (!DistributedLock.lock(LOCK_KEY + vo.getOrderId(), 30)) {{ return; }}\n"
                       f"    try {{ payService.process(vo); }} finally {{ DistributedLock.unlock(...); }}\n}}")
    if k == 2: return (f"select o.OrderID, o.TradeNo, e.PlatformId from OrderRecord{i%12+1:02d} o "
                       f"left join OrderDetail e on e.OrderID=o.OrderID where o.CreateTime>'2026-08-01' limit 200;")
    if k == 3: return json.dumps({"orderId": f"2606{i:08d}", "amount": round(random.uniform(10,2000),2),
                                  "status": random.choice(["PAID","SEIZED","FAILED"]), "备注": cn_text(20)}, ensure_ascii=False)
    return f"{random.choice(EN.split())} {cn_text(30)} https://api.internal.example.com/v1/task/{i}"

N = 100_000
ITEMS = [make_item(i) for i in range(N)]
RAW = sum(len(t.encode()) for t in ITEMS)
print(f"数据集 {N:,} 条，原始文本 {RAW/1024/1024:.2f} MB（这是分母）\n")

def bigram(s):
    """中文按 2-gram 切，非中文原样保留（应用层分词，对应 Swift 侧实现）"""
    out, buf = [], []
    def flush():
        nonlocal buf
        if len(buf) == 1: out.append(buf[0])
        elif len(buf) > 1: out.extend("".join(buf[i:i+2]) for i in range(len(buf)-1))
        buf = []
    for ch in s:
        if '一' <= ch <= '鿿': buf.append(ch)
        else:
            flush()
            out.append(ch)
    flush()
    return " ".join(out)

TOK = [bigram(t) for t in ITEMS]

def checkpoint(c): c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
def size(p): return sum(os.path.getsize(p+s) for s in ("","-wal","-shm") if os.path.exists(p+s))

QUERIES = ["订单支付", "幂等", "抢票退款", "DistributedLock", "PlatformId", "SEIZED", "分布式锁"]

def bench(detail, contentless=True):
    p = os.path.join(WORK, f"d_{detail}_{contentless}.sqlite")
    for s in ("","-wal","-shm"):
        if os.path.exists(p+s): os.remove(p+s)
    c = sqlite3.connect(p)
    c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA auto_vacuum=INCREMENTAL")
    c.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, body TEXT NOT NULL, created INTEGER, app TEXT)")
    c.executemany("INSERT INTO items(id,body,created,app) VALUES(?,?,?,?)",
                  [(i, ITEMS[i], 1754800000+i, "com.jetbrains.intellij") for i in range(N)])
    c.commit(); checkpoint(c)
    base = size(p)                                   # ← 只有原始数据的基线

    opt = "content=''" if contentless else "content='items', content_rowid='id'"
    c.execute(f"CREATE VIRTUAL TABLE fts USING fts5(tok, {opt}, detail={detail})")
    if contentless:
        c.executemany("INSERT INTO fts(rowid,tok) VALUES(?,?)", [(i, TOK[i]) for i in range(N)])
    else:
        # external content 模式下 fts 列必须能从 items 取到，这里用 tok 列不可行，跳过
        c.close(); return None
    c.commit(); checkpoint(c)
    total = size(p)
    idx = total - base

    # 检索：短语查询（bigram 必须连续出现）vs AND 查询
    lat_phrase, lat_and, hits_phrase, hits_and = [], [], [], []
    for q in QUERIES:
        toks = bigram(q).split()
        phrase = '"' + " ".join(toks) + '"'
        andq = " AND ".join(f'"{t}"' for t in toks)
        for expr, lat, hits in ((phrase, lat_phrase, hits_phrase), (andq, lat_and, hits_and)):
            try:
                t0 = time.perf_counter()
                r = c.execute("SELECT i.id FROM fts JOIN items i ON i.id=fts.rowid WHERE fts MATCH ? "
                              "ORDER BY rank LIMIT 20", (expr,)).fetchall()
                lat.append((time.perf_counter()-t0)*1000); hits.append(len(r))
            except sqlite3.OperationalError as e:
                lat.append(float('nan')); hits.append(-1)
    c.close()
    return dict(base=base, idx=idx, total=total,
                p_med=statistics.median(lat_phrase) if lat_phrase[0]==lat_phrase[0] else float('nan'),
                p_max=max(lat_phrase) if lat_phrase[0]==lat_phrase[0] else float('nan'),
                a_med=statistics.median(lat_and), a_max=max(lat_and),
                phrase_ok=hits_phrase[0]!=-1)

print("=== 实验1：FTS5 contentless 索引真实体积 & 检索延迟（10万条）===")
print(f"{'detail':8s} {'数据':>9s} {'索引':>9s} {'索引/原文':>9s} {'总计':>9s} {'膨胀':>6s}  {'短语查询':>18s}  {'AND查询':>14s}")
res = {}
for d in ("full","column","none"):
    r = bench(d)
    res[d] = r
    ps = f"{r['p_med']:.2f}/{r['p_max']:.2f}ms" if r['phrase_ok'] else "不支持"
    print(f"{d:8s} {r['base']/1048576:8.2f}M {r['idx']/1048576:8.2f}M {r['idx']/RAW*100:8.1f}% "
          f"{r['total']/1048576:8.2f}M {r['total']/RAW:5.2f}x  {ps:>18s}  {r['a_med']:.2f}/{r['a_max']:.2f}ms")

print("\n=== 实验2：多 representation 才是「1M 变 3M」的真凶 ===")
sample = ITEMS[0]*3
html = (f"<html><head><meta charset='utf-8'><style>p{{margin:0}}</style></head><body><p>"
        f"<span style='font-family:PingFang SC;font-size:14px;color:#1f2329'>{sample}</span></p></body></html>")
rtf = (r"{\rtf1\ansi\ansicpg936\cocoartf2761{\fonttbl\f0\fnil\fcharset134 PingFangSC-Regular;}"
       r"{\colortbl;\red255\green255\blue255;\red31\green35\blue41;}"
       r"\pard\tx560\pardirnatural\partightenfactor0\f0\fs28 \cf2 " + sample + "}")
sizes = {"plain":len(sample.encode()), "html":len(html.encode()), "rtf":len(rtf.encode())}
tot = sum(sizes.values())
print(f"  一次富文本复制的三份 representation：plain {sizes['plain']}B / html {sizes['html']}B / rtf {sizes['rtf']}B")
print(f"  合计 {tot}B = plain 的 {tot/sizes['plain']:.2f}x")
zt = sum(len(zlib.compress(x.encode(),6)) for x in (sample,html,rtf))
print(f"  三份各自压缩后合计 {zt}B = plain 原文的 {zt/sizes['plain']:.2f}x  ← 压缩后反而比只存 plain 还小")

print("\n=== 实验3：压缩收益（zlib-6 作 Apple LZFSE 代理）===")
for name, data in (("HTML 富文本",html),("RTF 富文本",rtf),("纯中文",ITEMS[0]*20),
                   ("Java 代码",ITEMS[1]*20),("JSON",ITEMS[3]*20),("短文本 80B",cn_text(40))):
    b = data.encode()
    t0=time.perf_counter(); z=zlib.compress(b,6); ct=(time.perf_counter()-t0)*1000
    t0=time.perf_counter(); zlib.decompress(z); dt=(time.perf_counter()-t0)*1000
    print(f"  {name:12s} {len(b):8d}B → {len(z):7d}B  {len(z)/len(b)*100:5.1f}%   压{ct:.3f}ms 解{dt:.3f}ms")

print("\n=== 实验4：加密的体积代价（SQLCipher 每 page 保留区）===")
t = res['column']['total']
pages = t/4096
print(f"  库 {t/1048576:.2f}MB ≈ {pages:.0f} pages × 64B 保留区 = +{pages*64/1048576:.2f}MB ({pages*64/t*100:.1f}%)")
print(f"  → 加密对【体积】几乎无影响；代价在【每次读 page 都要 AES 解密 + HMAC 校验】的延迟")
print(f"\n工作目录 {WORK}")
