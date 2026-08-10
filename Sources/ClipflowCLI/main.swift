import Foundation
import ClipflowCore
import ClipflowCapture

// clipflow-cli 不是附赠品 —— 它是「ClipflowCore 真的零 UI 依赖」的强制验证。
// 这个二进制不 import AppKit/SwiftUI，能跑通就证明核心解耦成立。

let usage = """
clipflow — Clipflow 核心引擎命令行客户端

用法:
  clipflow list [-n <条数>]          列出最近条目
  clipflow search <关键词> [-n <条数>]  全文检索（中文走 bigram 短语查询）
  clipflow show <id>                 查看某条的全部 representation
  clipflow add <文本>                 手动写入一条（测试用）
  clipflow seed <条数>                灌入测试数据
  clipflow stats                     存储统计
  clipflow optimize                  合并 FTS 段 + 回收空间
  clipflow rm <id>                   删除一条

选项:
  --root <路径>                       指定数据目录（默认 ~/Library/Application Support/Clipflow）
"""

// MARK: - 参数解析

var args = Array(CommandLine.arguments.dropFirst())

@MainActor
func takeOption(_ names: [String]) -> String? {
    for name in names {
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
    }
    return nil
}

let rootOpt = takeOption(["--root"])
let limit = Int(takeOption(["-n", "--limit"]) ?? "") ?? 20

guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

let paths = rootOpt.map { StoragePaths(root: URL(fileURLWithPath: $0)) }
    ?? StoragePaths.defaultLocation()

// MARK: - 输出helpers

@MainActor
func fmtBytes(_ n: Int) -> String {
    ByteCountFormatter().string(fromByteCount: Int64(n))
}

let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()

@MainActor
func oneLine(_ s: String, _ max: Int = 68) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "⏎ ")
        .replacingOccurrences(of: "\t", with: " ")
    var width = 0
    var out = ""
    for ch in flat {
        let w = (ch.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false) ? 2 : 1
        if width + w > max { out += "…"; break }
        out.append(ch); width += w
    }
    return out
}

@MainActor
func printItems(_ items: [ClipItem]) {
    if items.isEmpty { print("（无结果）"); return }
    for it in items {
        let id = it.id.map(String.init) ?? "-"
        let pin = it.pinned ? "📌" : "  "
        let sens = it.sensitivity == .sensitive ? "🔒" : "  "
        let app = it.sourceAppName ?? it.sourceBundleID ?? "-"
        print("\(pin)\(sens)#\(id.padding(toLength: max(5, id.count), withPad: " ", startingAt: 0)) "
              + "[\(it.kind.label)] \(dateFmt.string(from: it.createdAt))  \(app)")
        print("        \(oneLine(it.preview))")
    }
}

// MARK: - 执行

do {
    let store = try ClipflowStore(paths: paths)
    let ingest = IngestService(store: store)

    switch command {

    case "list", "ls":
        let t0 = Date()
        let items = try store.recent(limit: limit)
        printItems(items)
        print("\n\(items.count) 条 · \(String(format: "%.2f", Date().timeIntervalSince(t0) * 1000))ms")

    case "search", "s":
        guard let q = args.first else { print("需要关键词"); exit(1) }
        let t0 = Date()
        let items = try store.search(q, limit: limit)
        printItems(items)
        print("\n\(items.count) 条 · \(String(format: "%.2f", Date().timeIntervalSince(t0) * 1000))ms"
              + "  （排序 rowid DESC，非 rank —— 见 docs/01 §3.3）")

    case "show":
        guard let idStr = args.first, let id = Int64(idStr) else { print("需要 id"); exit(1) }
        let reps = try store.representations(of: id)
        if reps.isEmpty { print("#\(id) 不存在或无 representation"); exit(1) }
        print("#\(id) 共 \(reps.count) 个 representation：")
        for r in reps {
            let where_ = r.inlineData != nil ? "内联" : "CAS:\(r.blobHash?.prefix(12) ?? "-")"
            let data = try store.data(of: r)
            let actual = data?.count ?? 0
            print("  \(r.uti.padding(toLength: 34, withPad: " ", startingAt: 0)) "
                  + "\(fmtBytes(r.byteSize).padding(toLength: 10, withPad: " ", startingAt: 0)) "
                  + "\(r.codec.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(where_)")
            if let d = data, let s = String(data: d, encoding: .utf8), r.uti.contains("text") {
                print("      → \(oneLine(s, 60))")
            }
            if actual != r.byteSize {
                print("      ⚠️ 还原后 \(actual)B ≠ 原始 \(r.byteSize)B")
            }
        }

    case "add":
        guard !args.isEmpty else { print("需要文本"); exit(1) }
        let text = args.joined(separator: " ")
        let snap = RawSnapshot(
            representations: [("public.utf8-plain-text", Data(text.utf8))],
            sourceBundleID: "cli.clipflow", sourceAppName: "clipflow-cli"
        )
        if let id = try ingest.ingest(snap) {
            print("已写入 #\(id)")
        } else {
            print("被管道拦截，未写入")
        }

    case "seed":
        let n = Int(args.first ?? "") ?? 100
        let apps = [("com.jetbrains.intellij", "IntelliJ IDEA"), ("com.google.Chrome", "Chrome"),
                    ("com.apple.Terminal", "终端"), ("com.electron.lark", "飞书")]
        let samples: [(String, String)] = [
            ("text", "订单支付回调必须保证幂等性，不能依赖第三方防重"),
            ("code", "public void handlePay(PayNotifyVO vo) {\n    if (!DistributedLock.lock(KEY + vo.getOrderId(), 30)) return;\n    payService.process(vo);\n}"),
            ("sql",  "select o.OrderID, e.PlatformId from OrderRecord o left join OrderDetail e on e.OrderID=o.OrderID limit 200;"),
            ("url",  "https://api.internal.example.com/v1/task/run"),
            ("cn",   "分布式锁必须使用 SETNX 原子操作，禁止 getValue 加 setValue 伪锁"),
        ]
        let t0 = Date()
        var ok = 0
        for i in 0..<n {
            let (_, body) = samples[i % samples.count]
            let text = "\(body) #\(i) trackID=trace-2026\(String(format: "%06d", i))"
            let app = apps[i % apps.count]
            let snap = RawSnapshot(
                representations: [("public.utf8-plain-text", Data(text.utf8))],
                sourceBundleID: app.0, sourceAppName: app.1,
                capturedAt: Date().addingTimeInterval(-Double(n - i))
            )
            if (try ingest.ingest(snap)) != nil { ok += 1 }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        print("灌入 \(ok)/\(n) 条 · \(String(format: "%.0f", ms))ms · \(String(format: "%.0f", Double(ok) / (ms / 1000))) 条/s")

    case "stats":
        let s = try store.stats()
        print("条目          \(s.items)")
        print("内容库        \(fmtBytes(s.contentDBBytes))")
        print("索引库        \(fmtBytes(s.indexDBBytes))")
        print("CAS blob      \(s.blobCount) 个 / \(fmtBytes(s.blobBytes))")
        print("合计          \(fmtBytes(s.totalBytes))")
        print("数据目录      \(paths.root.path)")
        // 权限自检 —— Paste 用 644，我们必须 600
        for f in [paths.contentDB, paths.indexDB] where FileManager.default.fileExists(atPath: f.path) {
            let a = try FileManager.default.attributesOfItem(atPath: f.path)
            let perm = (a[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let flag = perm == 0o600 ? "✅" : "⚠️"
            print("\(flag) \(f.lastPathComponent) 权限 \(String(perm, radix: 8))")
        }

    case "poll":
        // 同步轮询 N 秒。不走 AsyncStream，用来隔离「捕获逻辑」与「异步层」的问题。
        setvbuf(stdout, nil, _IOLBF, 0)
        let seconds = Double(args.first ?? "") ?? 10
        let watcher = PasteboardWatcher()
        print("▶ 同步轮询 \(Int(seconds))s（200ms 一次）")
        let deadline = Date().addingTimeInterval(seconds)
        var n = 0
        while Date() < deadline {
            if let snap = watcher.pollOnce() {
                n += 1
                let utis = snap.representations.map(\.uti)
                let bytes = snap.representations.reduce(0) { $0 + $1.data.count }
                let app = snap.sourceAppName ?? snap.sourceBundleID ?? "?"
                if let id = (try? ingest.ingest(snap)) ?? nil {
                    // 必须按 id 取回，不能用 recent(1)：去重命中时 createdAt 不变，
                    // recent(1) 会取到别的条目，显示与实际写入的对不上。
                    let item = (try? store.item(id: id)) ?? nil
                    print("  #\(id) [\(item?.kind.label ?? "?")]"
                          + "\(item?.sensitivity == .sensitive ? " 🔒" : "") \(app) · "
                          + "\(utis.count) 种格式 · \(fmtBytes(bytes))")
                    print("      \(oneLine(item?.preview ?? "", 60))")
                    if utis.count > 1 { print("      \(utis.prefix(5).joined(separator: ", "))") }
                } else {
                    print("  ⊘ 拦截 (\(app)) · \(utis.prefix(3).joined(separator: ", "))")
                }
            }
            usleep(200_000)
        }
        print("\n共 \(n) 次变更")

    case "watch":
        // M1 主命令：真正开始记录你复制的内容。
        // macOS 没有剪贴板变更通知，只能轮询 changeCount。
        // 输出重定向到文件/管道时 stdout 默认是全缓冲（4KB），长驻进程的日志会卡在缓冲区里。
        // 改行缓冲，保证 `clipflow watch | tee` 和后台重定向都能实时看到。
        setvbuf(stdout, nil, _IOLBF, 0)

        let watcher = PasteboardWatcher()
        print("▶ 开始监听剪贴板（Ctrl+C 停止）")
        print("  轮询 200ms · 空闲 60s 后降到 1s · 密码管理器内容会被拦截\n")

        // 计数器要跨线程读写（消费任务写、信号处理器读），用带锁的引用类型。
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var _seen = 0, _stored = 0, _blocked = 0
            func seen()    { lock.lock(); _seen += 1; lock.unlock() }
            func stored()  { lock.lock(); _stored += 1; lock.unlock() }
            func blocked() { lock.lock(); _blocked += 1; lock.unlock() }
            var snapshot: (Int, Int, Int) {
                lock.lock(); defer { lock.unlock() }; return (_seen, _stored, _blocked)
            }
        }
        let counters = Counters()
        let sem = DispatchSemaphore(value: 0)

        // ⚠️ 必须用 Task.detached。
        //    main.swift 的顶层代码是 @MainActor，普通 `Task {}` 会**继承 MainActor 隔离**；
        //    而下面 sem.wait() 阻塞了主线程 → 这个 Task 永远排不上执行，静默什么都不干。
        //    （同步版 `poll` 没有这层，所以它一直是好的 —— 正是靠这个对照定位到本 bug。）
        let task = Task.detached {
            for await snap in watcher.start() {
                counters.seen()
                let utis = snap.representations.map(\.uti)
                let bytes = snap.representations.reduce(0) { $0 + $1.data.count }
                let app = snap.sourceAppName ?? snap.sourceBundleID ?? "?"

                if let id = (try? ingest.ingest(snap)) ?? nil {
                    counters.stored()
                    // 必须按 id 取回，不能用 recent(1)：去重命中时 createdAt 不变，
                    // recent(1) 会取到别的条目，显示与实际写入的对不上。
                    let item = (try? store.item(id: id)) ?? nil
                    let kind = item?.kind.label ?? "?"
                    let sens = item?.sensitivity == .sensitive ? " 🔒敏感" : ""
                    let kb = ByteCountFormatter().string(fromByteCount: Int64(bytes))
                    print("  #\(id) [\(kind)]\(sens) \(app) · \(utis.count) 种格式 · \(kb)")
                    print("      \(Formatting.oneLine(item?.preview ?? "", 64))")
                    if utis.count > 1 {
                        print("      格式: \(utis.prefix(6).joined(separator: ", "))\(utis.count > 6 ? " …" : "")")
                    }
                } else {
                    counters.blocked()
                    print("  ⊘ 已拦截（\(app)）· \(utis.prefix(3).joined(separator: ", "))")
                }
            }
            sem.signal()
        }

        // ⚠️ 信号源不能挂在 .main：下面 sem.wait() 会阻塞主线程，
        //    排在 main queue 上的 handler 永远轮不到执行 —— Ctrl+C 会失效。
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigQueue = DispatchQueue(label: "clipflow.signal")
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: sigQueue)
            src.setEventHandler {
                let (sn, st, bl) = counters.snapshot
                print("\n停止。本次捕获 \(sn) 次变更，写入 \(st) 条，拦截 \(bl) 条。")
                fflush(stdout)
                watcher.stop()
                task.cancel()
                exit(0)
            }
            src.resume()
            sources.append(src)
        }
        defer { sources.forEach { $0.cancel() } }
        sem.wait()

    case "bench":
        // 预热后重复测量，区分「首次连接开销」与「稳态查询耗时」。
        // 对照 docs/00 §4 的性能预算：搜索首屏 P95 < 16ms。
        let rounds = Int(args.first ?? "") ?? 50
        let n = try store.count()
        print("库内 \(n) 条 · 每项测 \(rounds) 次\n")

        func bench(_ label: String, _ body: () throws -> Int) rethrows {
            var ts: [Double] = []
            var hits = 0
            for _ in 0..<rounds {
                let t = Date()
                hits = try body()
                ts.append(Date().timeIntervalSince(t) * 1000)
            }
            let sorted = ts.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let budget = 16.0
            let flag = p95 < budget ? "✅" : "❌"
            print("\(flag) \(label.padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + "首次 \(String(format: "%6.2f", ts[0]))ms  "
                  + "中位 \(String(format: "%5.2f", sorted[sorted.count / 2]))ms  "
                  + "P95 \(String(format: "%5.2f", p95))ms  "
                  + "最差 \(String(format: "%6.2f", sorted.last!))ms  → \(hits) 条")
        }

        try bench("recent(20)")          { try store.recent(limit: 20).count }
        try bench("search 中文短语")      { try store.search("分布式锁", limit: 20).count }
        try bench("search 标识符")        { try store.search("DistributedLock", limit: 20).count }
        try bench("search 高频词")        { try store.search("订单", limit: 20).count }
        try bench("search 无命中")        { try store.search("不存在的关键词xyz", limit: 20).count }
        print("\n预算：搜索首屏 P95 < 16ms（docs/00 §4）")

    case "optimize":
        let t0 = Date()
        try store.optimize()
        print("完成 · \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms")

    case "rm":
        guard let idStr = args.first, let id = Int64(idStr) else { print("需要 id"); exit(1) }
        try store.delete(itemID: id)
        print("已删除 #\(id)")

    case "-h", "--help", "help":
        print(usage)

    default:
        print("未知命令: \(command)\n")
        print(usage)
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("错误: \(error)\n".utf8))
    exit(1)
}

// detached task 里不能调 @MainActor 的 helper，这里提供一份无隔离版本。
enum Formatting {
    static func oneLine(_ s: String, _ max: Int = 68) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎ ")
            .replacingOccurrences(of: "\t", with: " ")
        var width = 0, out = ""
        for ch in flat {
            let w = (ch.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false) ? 2 : 1
            if width + w > max { out += "…"; break }
            out.append(ch); width += w
        }
        return out
    }
}
