import Testing
import Foundation
@testable import ClipflowCore

// MARK: - 分词

@Suite("中文 bigram 分词")
struct BigramTests {

    @Test("连续汉字切成 bigram")
    func chineseBigram() {
        #expect(BigramTokenizer.tokenize("订单支付") == "订单 单支 支付")
    }

    @Test("单个孤立汉字原样保留")
    func singleIdeograph() {
        #expect(BigramTokenizer.tokenize("元") == "元")
    }

    @Test("中英混合：非汉字原样，汉字切 bigram")
    func mixed() {
        let t = BigramTokenizer.tokenize("查询orderId")
        #expect(t.contains("查询"))
        #expect(t.contains("o"))
    }

    @Test("查询表达式对汉字用短语查询（引号包裹）")
    func matchExpr() throws {
        let e = try #require(BigramTokenizer.matchExpression(for: "订单支付"))
        #expect(e == "\"订单 单支 支付\"")
    }

    @Test("多词之间是 AND")
    func multiTerm() throws {
        let e = try #require(BigramTokenizer.matchExpression(for: "订单 支付"))
        #expect(e.contains(" AND "))
    }

    @Test("空查询返回 nil")
    func emptyQuery() {
        #expect(BigramTokenizer.matchExpression(for: "   ") == nil)
    }

    @Test("引号被转义，不构成注入")
    func quoteEscaping() throws {
        let e = try #require(BigramTokenizer.matchExpression(for: "a\"b"))
        #expect(!e.contains("a\"b"))
    }
}

// MARK: - 压缩

@Suite("LZFSE 压缩")
struct CompressorTests {

    @Test("往返无损")
    func roundTrip() throws {
        let text = String(repeating: "订单支付回调幂等校验 orderId=26062215531467 ", count: 200)
        let data = Data(text.utf8)
        let packed = try #require(Compressor.compress(data))
        let back = try #require(Compressor.decompress(packed, originalSize: data.count))
        #expect(back == data)
    }

    @Test("重复文本压缩率显著")
    func ratio() throws {
        let data = Data(String(repeating: "分布式锁必须使用 SETNX 原子操作。", count: 300).utf8)
        let packed = try #require(Compressor.compress(data))
        #expect(Double(packed.count) / Double(data.count) < 0.15)
    }

    @Test("短文本不该压缩（阈值 512B）")
    func threshold() {
        #expect(!Compressor.shouldCompress(Data(repeating: 1, count: 120)))
        #expect(Compressor.shouldCompress(Data(repeating: 1, count: 1024)))
    }

    @Test("二进制往返无损")
    func binaryRoundTrip() throws {
        var d = Data(count: 40_000)
        for i in 0..<d.count { d[i] = UInt8((i * 7 + i / 13) % 251) }
        let packed = try #require(Compressor.compress(d))
        let back = try #require(Compressor.decompress(packed, originalSize: d.count))
        #expect(back == d)
    }
}

// MARK: - CAS

@Suite("内容寻址存储")
struct BlobStoreTests {

    private func tempStore() throws -> (BlobStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (BlobStore(root: dir), dir)
    }

    @Test("同内容只存一份")
    func dedup() throws {
        let (s, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Data("一张图的字节".utf8)
        let h1 = try s.put(d)
        let h2 = try s.put(d)
        #expect(h1 == h2)
        #expect(s.stats().count == 1)
    }

    @Test("两级分桶")
    func sharding() throws {
        let (s, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try s.put(Data("x".utf8))
        let path = s.url(for: h).path
        #expect(path.contains("/\(h.prefix(2))/\(h.dropFirst(2).prefix(2))/"))
    }

    @Test("读回一致 + 文件权限 600")
    func readBackAndPerms() throws {
        let (s, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Data(repeating: 42, count: 5000)
        let h = try s.put(d)
        #expect(try s.get(h) == d)
        let attrs = try FileManager.default.attributesOfItem(atPath: s.url(for: h).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

// MARK: - 端到端

@Suite("Store 端到端")
struct StoreTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    private func snap(_ text: String, app: String = "com.test.app") -> RawSnapshot {
        RawSnapshot(representations: [("public.utf8-plain-text", Data(text.utf8))],
                    sourceBundleID: app, sourceAppName: app)
    }

    @Test("写入后可检索（中文）")
    func ingestAndSearch() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try ingest.ingest(snap("订单支付回调必须保证幂等性"))
        try ingest.ingest(snap("分布式锁必须使用 SETNX 原子操作"))

        #expect(try store.search("订单支付").count == 1)
        #expect(try store.search("幂等").count == 1)
        #expect(try store.search("SETNX").count == 1)
        #expect(try store.search("不存在的词").isEmpty)
    }

    @Test("短语查询防误报：搜『订单支付』不该命中分别含二者的无关条目")
    func phrasePrecision() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try ingest.ingest(snap("订单已创建，稍后支付"))   // 含「订单」也含「支付」但不连续
        try ingest.ingest(snap("订单支付回调"))           // 真正连续

        let hits = try store.search("订单支付")
        #expect(hits.count == 1)
        #expect(hits.first?.preview.contains("回调") == true)
    }

    @Test("内容去重：同样内容写两次只有一条")
    func dedup() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let s = snap("完全一样的内容")
        let a = try ingest.ingest(s)
        let b = try ingest.ingest(s)
        #expect(a == b)
        #expect(try store.count() == 1)
    }

    @Test("多 representation 全量保真往返")
    func multiRepresentationFidelity() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        let plain = "订单支付回调"
        let html = "<html><body><b>\(String(repeating: plain, count: 80))</b></body></html>"
        let rtf = "{\\rtf1\\ansi \(String(repeating: plain, count: 80))}"
        let s = RawSnapshot(representations: [
            ("public.utf8-plain-text", Data(plain.utf8)),
            ("public.html", Data(html.utf8)),
            ("public.rtf", Data(rtf.utf8)),
        ])
        let id = try #require(try ingest.ingest(s))
        let reps = try store.representations(of: id)
        #expect(reps.count == 3)

        // 每个 representation 都必须能原样还原 —— 这是「粘回去一模一样」的前提
        for r in reps {
            let back = try #require(try store.data(of: r))
            switch r.uti {
            case "public.utf8-plain-text": #expect(String(data: back, encoding: .utf8) == plain)
            case "public.html":            #expect(String(data: back, encoding: .utf8) == html)
            case "public.rtf":             #expect(String(data: back, encoding: .utf8) == rtf)
            default: Issue.record("意外的 UTI \(r.uti)")
            }
        }
        // 大的走了 CAS，小的内联
        #expect(reps.contains { $0.inlineData != nil })
        #expect(reps.contains { $0.blobHash != nil })
    }

    @Test("密码管理器复制的内容不入库")
    func concealedDropped() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        let byUTI = RawSnapshot(representations: [
            ("public.utf8-plain-text", Data("hunter2".utf8)),
            ("org.nspasteboard.ConcealedType", Data()),
        ])
        #expect(try ingest.ingest(byUTI) == nil)

        let byApp = RawSnapshot(representations: [("public.utf8-plain-text", Data("hunter2".utf8))],
                                sourceBundleID: "com.bitwarden.desktop")
        #expect(try ingest.ingest(byApp) == nil)
        #expect(try store.count() == 0)
    }

    @Test("敏感内容标记为 sensitive 且不进索引")
    func sensitiveNotIndexed() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try ingest.ingest(snap("api_key = sk-abcdef0123456789abcdef"))
        let items = try store.recent()
        #expect(items.count == 1)
        #expect(items.first?.sensitivity == .sensitive)
        // 索引里搜不到 —— 索引不加密，敏感内容进去等于明文落盘
        #expect(try store.search("api_key").isEmpty)
    }

    @Test("文件引用只存路径，不复制文件内容")
    func fileRefStoresPathOnly() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        let url = "file:///Users/tom/Movies/200MB-video.mp4"
        let id = try #require(try ingest.ingest(
            RawSnapshot(representations: [("public.file-url", Data(url.utf8))])))
        let item = try #require(try store.recent().first)
        #expect(item.id == id)
        #expect(item.kind == .fileRef)
        #expect(item.byteSize < 200)   // 实测剪贴板给的就是 76 字节
    }

    @Test("最近排序：pinned 优先，其次 createdAt DESC")
    func recentOrdering() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        for i in 0..<5 { try ingest.ingest(snap("条目\(i)")) }
        let items = try store.recent()
        #expect(items.count == 5)
        for i in 1..<items.count {
            #expect(items[i - 1].createdAt >= items[i].createdAt)
        }
    }

    @Test("删除同时清内容库与索引库")
    func deleteClearsBoth() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(snap("待删除的订单支付记录")))
        #expect(try store.search("订单支付").count == 1)
        try store.delete(itemID: id)
        #expect(try store.count() == 0)
        #expect(try store.search("订单支付").isEmpty)
    }

    @Test("库文件权限必须是 600（Paste 用的是 644）")
    func filePermissions() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try IngestService(store: store).ingest(snap("触发建库"))
        store.paths.lockDatabasePermissions()

        for f in [store.paths.contentDB, store.paths.indexDB] {
            let a = try FileManager.default.attributesOfItem(atPath: f.path)
            #expect((a[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                    "\(f.lastPathComponent) 权限不是 600")
        }
        let d = try FileManager.default.attributesOfItem(atPath: store.paths.root.path)
        #expect((d[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

// MARK: - 架构约束（代码禁令）

@Suite("架构约束")
struct ArchitectureTests {

    /// `ORDER BY rank` 是本项目最贵的性能陷阱：
    /// 实测 2 万条命中时 rank 要 46ms，rowid DESC 只要 0.30ms —— 快 150 倍。
    /// 这条测试就是 docs/00 §3.4 说的 lint 规则。
    @Test("源码中不得出现 ORDER BY rank")
    func noOrderByRank() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClipflowCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
            .appending(path: "Sources")

        let e = try #require(FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let f as URL in e where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            scanned += 1
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lower = line.lowercased()
                // 注释里说明「为什么不用」是允许的，只禁真实 SQL
                guard !lower.contains("//"), !lower.contains("///") else { continue }
                #expect(!lower.contains("order by rank"),
                        "\(f.lastPathComponent):\(n + 1) 出现了 ORDER BY rank")
            }
        }
        #expect(scanned > 0, "没扫到源文件，测试本身失效了")
    }

    /// Core 必须零 UI 依赖 —— 这是「呈现层可整层替换」的前提
    @Test("ClipflowCore 不得 import AppKit / SwiftUI")
    func coreHasNoUIImports() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCore")

        let e = try #require(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
        for case let f as URL in e where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            for banned in ["import AppKit", "import SwiftUI", "import UIKit", "import VisionKit"] {
                #expect(!text.contains(banned), "\(f.lastPathComponent) 引入了 \(banned)")
            }
        }
    }
}

// MARK: - 捕获层约束（不依赖 AppKit 的部分）

@Suite("捕获层约束")
struct CaptureContractTests {

    /// 捕获层必须独立于 Core —— NSPasteboard 在 AppKit 里，而 Core 禁 import AppKit
    @Test("ClipflowCapture 独立成 target，Core 不得依赖它")
    func captureIsSeparate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = root.appending(path: "Sources/ClipflowCapture")
        #expect(FileManager.default.fileExists(atPath: capture.path),
                "ClipflowCapture target 不存在")

        // Core 里不许出现对 Capture 的引用
        let core = root.appending(path: "Sources/ClipflowCore")
        let e = try #require(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
        for case let f as URL in e where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            #expect(!text.contains("import ClipflowCapture"),
                    "\(f.lastPathComponent) 反向依赖了捕获层")
        }
    }

    /// 读取策略必须独立成文件 —— 它是 M1 重构的核心产物，
    /// 承载"为什么不能把广告类型全读一遍"这条最贵的教训。
    /// 详细断言见「剪贴板类型读取策略」套件。
    @Test("类型读取策略独立成 TypePolicy.swift")
    func typePolicyIsSeparateFile() throws {
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/TypePolicy.swift")
        #expect(FileManager.default.fileExists(atPath: p.path),
                "TypePolicy.swift 不存在 —— 读取策略不该散落在 Watcher 里")

        // Watcher 必须真的用上策略，不能绕过
        let w = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/PasteboardWatcher.swift")
        let ws = try String(contentsOf: w, encoding: .utf8)
        #expect(ws.contains("TypePolicy.classify"), "Watcher 没走分级策略")
        #expect(ws.contains("NegativeTypeCache"), "Watcher 没接负缓存")
    }
}

// MARK: - 类型读取策略（M1 重构后的核心防线）

@Suite("剪贴板类型读取策略")
struct TypePolicyTests {

    private func policySource() throws -> String {
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/TypePolicy.swift")
        return try String(contentsOf: p, encoding: .utf8)
    }

    /// 根因：只要剪贴板上有 RTF，macOS 就广告一个谁都兑现不了的
    /// public.utf16-external-plain-text，首读阻塞 18.5~23.8 秒后返回 badPasteboardFlavorErr。
    /// 三种写入方式全复现，含 NSAttributedString（TextEdit/浏览器/飞书的标准写法）。
    @Test("已知不可兑现类型必须在种子列表里")
    func knownBadSeeded() throws {
        let s = try policySource()
        #expect(s.contains("public.utf16-external-plain-text"))
        #expect(s.contains("knownUnfulfillable"))
    }

    /// 可信类型不设看门狗是刻意的：大图合法读取可能超过任何短阈值，
    /// 设了超时反而把真数据误判成坏类型丢掉。
    @Test("可信类型列表覆盖核心保真格式")
    func trustedCoversCore() throws {
        let s = try policySource()
        for uti in ["public.utf8-plain-text", "public.rtf", "public.html",
                    "public.png", "public.tiff", "public.file-url"] {
            #expect(s.contains(uti), "可信列表缺 \(uti)")
        }
    }

    /// 硬编码列表列不全各家 App 的私有 UTI，负缓存才是正确性依赖。
    @Test("必须有负缓存自学习，不能只靠硬编码列表")
    func negativeCacheExists() throws {
        let s = try policySource()
        #expect(s.contains("NegativeTypeCache"))
        #expect(s.contains("markBad"))
        #expect(s.contains("totalReadBudget"), "缺少单次快照总读取预算")
    }

    /// 启动前复制的内容不该永久丢失
    @Test("启动时捕获现有剪贴板内容")
    func captureOnStart() throws {
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/PasteboardWatcher.swift")
        let s = try String(contentsOf: p, encoding: .utf8)
        #expect(s.contains("captureOnStart"))
    }
}
