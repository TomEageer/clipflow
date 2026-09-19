import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ClipflowCore

// MARK: - 分词

@Suite("检索分词")
struct TokenizerTests {

    @Test("连续汉字切成 bigram")
    func chineseBigram() {
        #expect(SearchTokenizer.tokenize("订单支付") == "订单 单支 支付")
    }

    @Test("单个孤立汉字原样保留")
    func singleIdeograph() {
        #expect(SearchTokenizer.tokenize("元") == "元")
    }

    /// 拉丁按**词**入索引，不是按字符 —— 按字符会让短语查询跨词乱拼
    @Test("拉丁按词入索引，并拆出 camelCase 子词")
    func latinWords() {
        let t = SearchTokenizer.tokenize("leaderStaffNo")
        #expect(t.split(separator: " ").contains("leaderstaffno"))
        #expect(t.split(separator: " ").contains("staff"))
        #expect(t.split(separator: " ").contains("leader"))
        // 单字符子词不要，否则搜 a 命中一切
        #expect(SearchTokenizer.tokenize("userA").split(separator: " ").contains("a") == false)
    }

    @Test("字母数字边界也算子词边界")
    func digitBoundary() {
        let t = SearchTokenizer.tokenize("StaffInfo12").split(separator: " ").map(String.init)
        #expect(t.contains("staffinfo12"))
        #expect(t.contains("staff"))
        #expect(t.contains("12"))
    }

    @Test("连续大写后接小写：HTTPServer → http + server")
    func acronym() {
        let t = SearchTokenizer.tokenize("HTTPServer").split(separator: " ").map(String.init)
        #expect(t.contains("http"))
        #expect(t.contains("server"))
    }

    @Test("中英混合：汉字切 bigram，英文整词")
    func mixed() {
        let t = SearchTokenizer.tokenize("查询orderId").split(separator: " ").map(String.init)
        #expect(t.contains("查询"))
        #expect(t.contains("orderid"))
        #expect(t.contains("order"))
    }

    @Test("查询表达式对汉字用短语查询（引号包裹）")
    func matchExpr() throws {
        let e = try #require(SearchTokenizer.matchExpression(for: "订单支付"))
        #expect(e == "\"订单 单支 支付\"")
    }

    @Test("英文查询用前缀匹配")
    func latinPrefix() throws {
        let e = try #require(SearchTokenizer.matchExpression(for: "user"))
        #expect(e == "\"user\"*")
    }

    @Test("多词之间是 AND")
    func multiTerm() throws {
        let e = try #require(SearchTokenizer.matchExpression(for: "订单 支付"))
        #expect(e.contains(" AND "))
    }

    @Test("空查询返回 nil")
    func emptyQuery() {
        #expect(SearchTokenizer.matchExpression(for: "   ") == nil)
        #expect(SearchTokenizer.matchExpression(for: " ,. ") == nil)
    }

    @Test("引号被转义，不构成注入")
    func quoteEscaping() throws {
        let e = try #require(SearchTokenizer.matchExpression(for: "a\"b"))
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
        RawSnapshot(representations: [("public.utf8-plain-text", Data(text.utf8), 0)],
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
            ("public.utf8-plain-text", Data(plain.utf8), 0),
            ("public.html", Data(html.utf8), 0),
            ("public.rtf", Data(rtf.utf8), 0),
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
            ("public.utf8-plain-text", Data("hunter2".utf8), 0),
            ("org.nspasteboard.ConcealedType", Data(), 0),
        ])
        #expect(try ingest.ingest(byUTI) == nil)

        let byApp = RawSnapshot(representations: [("public.utf8-plain-text", Data("hunter2".utf8), 0)],
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
            RawSnapshot(representations: [("public.file-url", Data(url.utf8), 0)])))
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
            // ⚠️ **必须先剥掉注释再扫。** 裸文本匹配会把「这里禁 import SwiftUI」
            // 这种注释也判成违规 —— 一条本来是好事的注释反倒让测试挂掉（真发生过）。
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let r = line.range(of: "//") else { return line }
                    return line[line.startIndex..<r.lowerBound]
                }
                .joined(separator: "\n")
            for banned in ["import AppKit", "import SwiftUI", "import UIKit", "import VisionKit"] {
                #expect(!code.contains(banned), "\(f.lastPathComponent) 引入了 \(banned)")
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
        #expect(ws.contains("TypePolicy.shouldRead"), "Watcher 没走类型策略")
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

    /// ⚠️ 回归测试：曾经把 public.utf16-external-plain-text 当成"系统缺陷"跳过，
    /// 那是错的 —— 它是正常的 lazy promise，含真数据（实测 1522B），
    /// 跳过会造成保真度倒退。根因是当时的测试写入进程没跑 run loop。
    ///
    /// 这条测试守着：**不许再把它列进任何过滤名单**。
    @Test("不得跳过 public.utf16-external-plain-text（曾误判，含真数据）")
    func doesNotSkipLegitimateType() throws {
        let s = try policySource()
        let inFilter = s.contains("harmfulTypes: Set<String> = [")
            && s.range(of: #"harmfulTypes[^\]]*utf16-external"#, options: .regularExpression) != nil
        #expect(!inFilter, "utf16-external-plain-text 被重新加进过滤名单了 —— 它含真数据，跳过会掉保真度")

        let w = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/PasteboardWatcher.swift")
        let ws = try String(contentsOf: w, encoding: .utf8)
        // Watcher 里也不许出现硬编码跳过
        #expect(!ws.contains("skippedTypes"), "Watcher 里出现了硬编码跳过列表")
    }

    /// 过滤规则必须有真实依据（Maccy 的 issue 编号），不能凭推测加
    @Test("有害类型过滤只保留有真实依据的几条")
    func harmfulFiltersAreEvidenceBased() throws {
        let s = try policySource()
        #expect(s.contains("dyn."), "缺 dyn.* 动态类型过滤")
        #expect(s.contains("microsoft"), "缺 Word 链接源过滤（Maccy #613/#770）")
    }

    /// 看门狗现在只是边缘情况兜底（拥有者进程退出/挂死），不是主要机制。
    /// 阈值必须够宽松 —— 太短会把大图的合法读取误判成坏类型丢掉。
    @Test("看门狗保留为兜底，且阈值不过短")
    func watchdogIsGenerous() throws {
        let s = try policySource()
        #expect(s.contains("readTimeout"))
        #expect(s.contains("totalReadBudget"))
        #expect(s.contains("NegativeTypeCache"))
        // 阈值 >= 1 秒
        let ok = s.contains("readTimeout: TimeInterval = 2.0") || s.contains("readTimeout: TimeInterval = 1")
        #expect(ok, "看门狗阈值过短，会误伤大图的合法读取")
    }

    /// 错误结论必须留在代码里，防止后人重蹈覆辙
    @Test("被推翻的错误结论要有记录")
    func documentsTheRefutedConclusion() throws {
        let s = try policySource()
        #expect(s.contains("run loop"), "缺少『测试进程未跑 run loop 才是根因』的记录")
    }

    @Test("启动时捕获现有剪贴板内容")
    func captureOnStart() throws {
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/PasteboardWatcher.swift")
        let s = try String(contentsOf: p, encoding: .utf8)
        #expect(s.contains("captureOnStart"))
    }
}

// MARK: - 缩略图

@Suite("缩略图")
struct ThumbnailTests {

    /// 造一张真 PNG（不依赖 AppKit —— Core 的测试也不该引入 UI 框架）
    private func makePNG(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for i in 0..<8 {
            ctx.fillEllipse(in: CGRect(x: i * width / 10, y: height / 3, width: 20, height: 20))
        }
        let cg = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("能从 PNG 生成缩略图，且明显更小")
    func generates() throws {
        let png = try makePNG(width: 1600, height: 1000)
        let thumb = try #require(ThumbnailStore.makeThumbnail(from: png, maxPixel: 96))
        #expect(thumb.count < png.count / 4)
        let size = try #require(ThumbnailStore.pixelSize(of: thumb))
        #expect(max(size.width, size.height) <= 96)
    }

    @Test("能读出像素尺寸（只解析元数据头，不解码像素）")
    func readsDimensions() throws {
        let png = try makePNG(width: 800, height: 500)
        let size = try #require(ThumbnailStore.pixelSize(of: png))
        #expect(size.width == 800)
        #expect(size.height == 500)
    }

    @Test("非图片数据返回 nil，不崩")
    func nonImageIsNil() {
        let junk = Data("这不是图片，只是一段中文文本".utf8)
        #expect(ThumbnailStore.makeThumbnail(from: junk, maxPixel: 96) == nil)
        #expect(ThumbnailStore.pixelSize(of: junk) == nil)
    }

    @Test("磁盘缓存命中后不重复生成")
    func cachesOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-thumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailStore(root: dir)
        let png = try makePNG(width: 400, height: 300)

        var generatorCalls = 0
        let a = store.thumbnail(for: "hash-a", imageData: { generatorCalls += 1; return png }())
        let b = store.thumbnail(for: "hash-a", imageData: { generatorCalls += 1; return png }())
        #expect(a != nil)
        #expect(a == b)
        // 第二次仍会求值 autoclosure（Swift 语义），但不该再写盘 —— 校验文件只有一个
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
    }

    @Test("图片条目的 preview 带上像素尺寸，不再是无意义的『[图片 278 KB]』")
    func previewHasDimensions() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipflowStore(paths: StoragePaths(root: dir))
        let png = try makePNG(width: 640, height: 480)

        let id = try #require(try IngestService(store: store)
            .ingest(RawSnapshot(representations: [("public.png", png, 0)])))
        let item = try #require(try store.item(id: id))
        #expect(item.kind == .image)
        #expect(item.preview.contains("640×480"), "preview 里没有像素尺寸：\(item.preview)")

        // 缩略图能生成
        #expect(store.thumbnail(for: item) != nil)
    }
}

// MARK: - 列表行为

@Suite("列表行为")
struct ListBehaviorTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }
    private func snap(_ t: String) -> RawSnapshot {
        RawSnapshot(representations: [("public.utf8-plain-text", Data(t.utf8), 0)])
    }

    /// 重新复制一条老内容，它必须冒到列表顶部。
    /// 之前按 createdAt 排序 → 去重只更新 lastUsedAt → 老条目仍沉在底部，
    /// 用户明明刚复制过却要翻半天。所有剪贴板工具都是置顶的。
    @Test("重新复制的老内容要冒到顶部")
    func recopiedItemFloatsToTop() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try ingest.ingest(snap("最早的内容"))
        try ingest.ingest(snap("中间的内容"))
        try ingest.ingest(snap("最新的内容"))
        #expect(try store.recent().first?.preview == "最新的内容")

        // 重新复制第一条
        try ingest.ingest(snap("最早的内容"))
        #expect(try store.recent().first?.preview == "最早的内容",
                "重新复制的内容没有冒到顶部")
        #expect(try store.count() == 3, "不该新建条目")
    }

    /// 粘贴过的内容也要冒到顶部 —— 下次唤出就在手边
    @Test("粘贴过的内容冒到顶部")
    func pastedItemFloatsToTop() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let first = try #require(try ingest.ingest(snap("第一条")))
        try ingest.ingest(snap("第二条"))
        #expect(try store.recent().first?.preview == "第二条")

        try store.touch(itemID: first)
        #expect(try store.recent().first?.preview == "第一条")
    }

    /// 分组取代了置顶：分组有自己的标签页，**不再插队到「全部」顶部** ——
    /// 那样会把用户刚复制的东西挤下去，反而更难找。
    @Test("分组条目不插队，但按分组能单独筛出来")
    func groupFiltering() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let old = try #require(try ingest.ingest(snap("很老的条目")))
        for i in 0..<5 { try ingest.ingest(snap("后来的 \(i)")) }

        let g = try store.createGroup(name: "常用")
        try store.setGroup(g, itemID: old)

        // 「全部」里仍按最近排，不因为分组而插队
        #expect(try store.recent().first?.preview != "很老的条目")
        // 切到分组只剩它
        let inGroup = try store.recent(groupID: g)
        #expect(inGroup.count == 1)
        #expect(inGroup.first?.preview == "很老的条目")
        #expect(try store.countsByGroup()[g] == 1)

        // 删分组只解绑，**不删条目** —— 一次误点不能连内容一起没掉
        try store.deleteGroup(g)
        #expect(try store.groups().isEmpty)
        #expect(try store.recent().count == 6)
    }

    @Test("命名后能直接搜名字找到")
    func searchByName() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(snap("aGVsbG8gd29ybGQK")))

        // 起名前，搜名字搜不到
        #expect(try store.search("生产库密钥").isEmpty)

        try store.setName("生产库密钥", itemID: id)
        let hits = try store.search("生产库密钥")
        #expect(hits.count == 1, "起了名却搜不到 —— setName 忘了重建 FTS 行")
        #expect(hits.first?.name == "生产库密钥")
        // 原内容仍然能搜到，改名不该把原来的索引冲掉
        #expect(try store.search("aGVsbG8").count == 1)

        // 清除名字后又搜不到了
        try store.setName(nil, itemID: id)
        #expect(try store.search("生产库密钥").isEmpty)
        #expect(try store.search("aGVsbG8").count == 1)
    }
}

// MARK: - 粘贴语义

@Suite("粘贴语义")
struct PasteSemanticsTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }
    private func snap(_ t: String) -> RawSnapshot {
        RawSnapshot(representations: [("public.utf8-plain-text", Data(t.utf8), 0)])
    }

    /// 从历史里粘贴一条，语义上等于"重新复制了它"：
    /// 它要冒到列表顶部，之后再按 ⌘V 也应该还是这条（不恢复旧剪贴板）。
    @Test("粘贴后该条置顶且 useCount 增加")
    func pasteActsLikeRecopy() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        let target = try #require(try ingest.ingest(snap("要粘贴的老内容")))
        for i in 0..<4 { try ingest.ingest(snap("后来的 \(i)")) }
        #expect(try store.recent().first?.preview != "要粘贴的老内容")

        try store.touch(itemID: target)

        let top = try #require(try store.recent().first)
        #expect(top.preview == "要粘贴的老内容")
        #expect(top.useCount >= 1)
    }

    /// 粘贴路径上不能有"备份整个剪贴板"这种可能阻塞的操作。
    /// 读剪贴板实测可阻塞秒级，挡在粘贴前会直接毁掉手感。
    @Test("Paster 不再备份/恢复剪贴板")
    func noClipboardRestore() throws {
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/Paster.swift")
        let s = try String(contentsOf: p, encoding: .utf8)
        #expect(!s.contains("restoreAfter"), "还留着恢复旧剪贴板的逻辑")
        #expect(s.contains("waitingFor"), "缺少『轮询等前台就绪』的接口")
    }

    /// 固定 sleep 要么太短（按键打到还没切回来的 App 上）要么太长（用户感到延迟）。
    /// 必须轮询前台 App。
    @Test("等待前台用轮询而非固定 sleep")
    func pollsInsteadOfSleeping() throws {
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ClipflowCapture/Paster.swift")
        let s = try String(contentsOf: p, encoding: .utf8)
        #expect(s.contains("frontmostApplication"), "没有轮询前台 App")
        #expect(!s.contains("asyncAfter(deadline: .now() + 0.6)"), "还有固定 600ms 延迟")
    }
}

// MARK: - 多文件

@Suite("多文件保真")
struct MultiItemTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    /// 复制多个文件时剪贴板上是多个 NSPasteboardItem，每个挂一个 public.file-url。
    /// 拍平成一个列表的话，写回时同一 UTI 反复 setData 后者覆盖前者，三个文件只剩一个。
    @Test("多文件复制要保留每个 item 的结构")
    func preservesMultipleItems() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = ["file:///Users/tom/a.xlsx", "file:///Users/tom/b.pdf", "file:///Users/tom/c.png"]
        let snap = RawSnapshot(representations: urls.enumerated().map {
            ("public.file-url", Data($1.utf8), $0)
        })
        let id = try #require(try IngestService(store: store).ingest(snap))

        let reps = try store.representations(of: id)
        #expect(reps.count == 3, "三个文件被合并了")
        #expect(Set(reps.map(\.itemIndex)) == [0, 1, 2], "itemIndex 没保留")

        // 每个文件的路径都要能原样还原
        var restored: [String] = []
        for r in reps.sorted(by: { $0.itemIndex < $1.itemIndex }) {
            let d = try #require(try store.data(of: r))
            restored.append(try #require(String(data: d, encoding: .utf8)))
        }
        #expect(restored == urls)
    }

    @Test("单个复制里的多种格式仍归到同一 item")
    func singleItemKeepsIndexZero() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = RawSnapshot(representations: [
            ("public.utf8-plain-text", Data("文本".utf8), 0),
            ("public.rtf", Data("{\\rtf1 文本}".utf8), 0),
        ])
        let id = try #require(try IngestService(store: store).ingest(snap))
        let reps = try store.representations(of: id)
        #expect(reps.count == 2)
        #expect(reps.allSatisfy { $0.itemIndex == 0 })
    }
}

// MARK: - 清理

@Suite("清理策略")
struct CleanupTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }
    private func snap(_ t: String) -> RawSnapshot {
        RawSnapshot(representations: [("public.utf8-plain-text", Data(t.utf8), 0)])
    }

    /// 已分组的条目永不自动清理 —— 用户明确归过类的东西不能悄悄删掉。
    /// （这条保护原来挂在 pinned 上，置顶被分组取代后必须跟着平移过来。）
    @Test("已分组的条目不被保留期清理")
    func groupedSurvivesRetention() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        let kept = try #require(try ingest.ingest(snap("要留着的")))
        try ingest.ingest(snap("会被清掉的"))
        let g = try store.createGroup(name: "常用")
        try store.setGroup(g, itemID: kept)

        var s = ClipflowSettings()
        s.retention = .days7
        s.maxStorageMB = 0
        // 假装现在是 30 天后
        let r = try store.cleanup(settings: s, now: Date().addingTimeInterval(30 * 86400))
        #expect(r.byRetention == 1)
        let left = try store.recent()
        #expect(left.count == 1)
        #expect(left.first?.preview == "要留着的")
    }

    @Test("敏感条目按独立 TTL 清理")
    func sensitiveTTL() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try ingest.ingest(snap("api_key = sk-live-abcdef123456"))
        try ingest.ingest(snap("普通文本"))

        var s = ClipflowSettings()
        s.sensitiveTTL = .seconds60
        s.retention = .forever
        s.maxStorageMB = 0
        let r = try store.cleanup(settings: s, now: Date().addingTimeInterval(120))
        #expect(r.bySensitiveTTL == 1)
        #expect(try store.count() == 1)
        #expect(try store.recent().first?.preview == "普通文本")
    }

    @Test("条目数上限淘汰最久未用的")
    func maxItems() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        for i in 0..<10 { try ingest.ingest(snap("条目 \(i)")) }

        var s = ClipflowSettings()
        s.maxItems = 4
        s.retention = .forever
        s.maxStorageMB = 0
        let r = try store.cleanup(settings: s)
        #expect(r.byMaxItems == 6)
        #expect(try store.count() == 4)
        // 留下的应该是最近的
        #expect(try store.recent().first?.preview == "条目 9")
    }

    /// 删条目只删数据库行，CAS 里的附件要单独回收，否则磁盘只涨不降
    @Test("孤儿附件能被回收")
    func vacuumOrphanBlobs() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        let big = String(repeating: "需要外置到 CAS 的长内容。", count: 200)
        let id = try #require(try ingest.ingest(snap(big)))
        #expect(store.blobs.stats().count > 0)

        try store.delete(itemID: id)
        let v = try store.vacuumBlobs()
        #expect(v.removed > 0, "孤儿附件没被回收")
        #expect(store.blobs.stats().count == 0)
    }

    @Test("按类型统计占用")
    func breakdown() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try ingest.ingest(snap("纯文本一"))
        try ingest.ingest(snap("纯文本二"))
        try ingest.ingest(RawSnapshot(representations: [("public.file-url", Data("file:///a".utf8), 0)]))

        let rows = try store.breakdownByKind()
        #expect(rows.contains { $0.kind == .text && $0.count == 2 })
        #expect(rows.contains { $0.kind == .fileRef && $0.count == 1 })
    }

    @Test("排序方式都能跑通")
    func sortOrders() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        for i in 0..<5 { try ingest.ingest(snap("条目 \(i)")) }
        for order in ClipflowStore.SortOrder.allCases {
            #expect(try store.browse(sort: order).count == 5, "\(order) 挂了")
        }
    }
}

// MARK: - 设置持久化与生效

@Suite("设置")
struct SettingsTests {

    private func tempDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "clipflow-test-\(UUID().uuidString)")!
        return d
    }

    @Test("设置能存能读，改动不丢")
    func roundTrip() {
        let d = tempDefaults()
        var s = ClipflowSettings()
        s.maxStorageMB = 4096
        s.maxItems = 5000
        s.retention = .days30
        s.sensitiveTTL = .minutes10
        s.save(to: d)

        let back = ClipflowSettings.load(from: d)
        #expect(back.maxStorageMB == 4096)
        #expect(back.maxItems == 5000)
        #expect(back.retention == .days30)
        #expect(back.sensitiveTTL == .minutes10)
    }

    @Test("没存过时给出合理默认值")
    func defaults() {
        let s = ClipflowSettings.load(from: tempDefaults())
        #expect(s.maxStorageMB == 2048)
        #expect(s.retention == .days365)
        #expect(s.sensitiveTTL == .seconds60)
        #expect(s.captureOnStart)
    }

    /// 存储上限必须真的生效 —— 之前用输入框设不上，本质是设了也没写进去
    @Test("存储上限触发清理")
    func storageLimitTriggersCleanup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipflowStore(paths: StoragePaths(root: dir))
        let ingest = IngestService(store: store)

        // 灌到明显超过 1MB
        let chunk = String(repeating: "存储上限测试内容，需要占一些空间。", count: 400)
        for i in 0..<40 { try ingest.ingest(RawSnapshot(
            representations: [("public.utf8-plain-text", Data("\(i) \(chunk)".utf8), 0)])) }
        let before = try store.count()
        #expect(before == 40)

        var s = ClipflowSettings()
        s.retention = .forever
        s.maxItems = 0
        s.maxStorageMB = 1          // 1MB 上限，必然触发
        let r = try store.cleanup(settings: s)
        #expect(r.byStorage > 0, "存储上限没触发清理")
        #expect(try store.count() < before)
    }

    /// 0 表示不限制，不能被当成"上限为 0 所以全删"
    @Test("上限设为 0 表示不限制")
    func zeroMeansUnlimited() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipflowStore(paths: StoragePaths(root: dir))
        let ingest = IngestService(store: store)
        for i in 0..<10 { try ingest.ingest(RawSnapshot(
            representations: [("public.utf8-plain-text", Data("条目 \(i)".utf8), 0)])) }

        var s = ClipflowSettings()
        s.retention = .forever
        s.maxItems = 0
        s.maxStorageMB = 0
        let r = try store.cleanup(settings: s)
        #expect(r.total == 0, "不限制却删了东西")
        #expect(try store.count() == 10)
    }
}

// MARK: - 分类过滤

@Suite("分类过滤")
struct KindFilterTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    /// 过滤必须在 SQL 里做。若先取最近 N 条再客户端筛，
    /// 「最近 200 条里只有 3 张图」时用户会以为图片丢了。
    @Test("按类型过滤走 SQL，不受 limit 影响")
    func filtersInSQL() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        // 先写 1 张图，再写 50 条文本把它挤到很后面
        try ingest.ingest(RawSnapshot(representations: [("public.png", Data(repeating: 9, count: 300), 0)]))
        for i in 0..<50 {
            try ingest.ingest(RawSnapshot(
                representations: [("public.utf8-plain-text", Data("文本 \(i)".utf8), 0)]))
        }

        // 只取最近 10 条时，图片已经被挤出去了
        #expect(try store.recent(limit: 10).contains { $0.kind == .image } == false)
        // 但按类型过滤必须能取到
        let images = try store.recent(limit: 10, kinds: [.image])
        #expect(images.count == 1)
        #expect(images.first?.kind == .image)
    }

    @Test("多类型合并过滤")
    func multipleKinds() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try ingest.ingest(RawSnapshot(representations: [("public.utf8-plain-text", Data("纯文本".utf8), 0)]))
        try ingest.ingest(RawSnapshot(representations: [("public.file-url", Data("file:///a".utf8), 0)]))
        try ingest.ingest(RawSnapshot(representations: [("public.png", Data(repeating: 7, count: 200), 0)]))

        #expect(try store.recent(kinds: [.text, .fileRef]).count == 2)
        #expect(try store.recent(kinds: [.image]).count == 1)
        #expect(try store.recent(kinds: nil).count == 3)
    }

    @Test("各类型计数")
    func counts() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        for i in 0..<3 {
            try ingest.ingest(RawSnapshot(
                representations: [("public.utf8-plain-text", Data("文本 \(i)".utf8), 0)]))
        }
        try ingest.ingest(RawSnapshot(representations: [("public.file-url", Data("file:///b".utf8), 0)]))

        let c = try store.countsByKind()
        #expect(c[.text] == 3)
        #expect(c[.fileRef] == 1)
    }
}

// MARK: - 浏览筛选

@Suite("浏览筛选")
struct BrowseFilterTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }
    private func snap(_ t: String, app: String) -> RawSnapshot {
        RawSnapshot(representations: [("public.utf8-plain-text", Data(t.utf8), 0)],
                    sourceBundleID: app, sourceAppName: app)
    }

    @Test("按来源筛选")
    func filterBySource() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try ingest.ingest(snap("来自 Chrome 的一", app: "Chrome"))
        try ingest.ingest(snap("来自 Chrome 的二", app: "Chrome"))
        try ingest.ingest(snap("来自终端的", app: "Terminal"))

        #expect(try store.browse(source: "Chrome").count == 2)
        #expect(try store.browse(source: "Terminal").count == 1)
        #expect(try store.browse().count == 3)
    }

    @Test("来源与类型可叠加")
    func combinedFilters() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try ingest.ingest(snap("Chrome 文本", app: "Chrome"))
        try ingest.ingest(RawSnapshot(
            representations: [("public.file-url", Data("file:///x".utf8), 0)],
            sourceBundleID: "Chrome", sourceAppName: "Chrome"))

        #expect(try store.browse(kind: .text, source: "Chrome").count == 1)
        #expect(try store.browse(kind: .fileRef, source: "Chrome").count == 1)
        #expect(try store.browse(kind: .image, source: "Chrome").isEmpty)
    }

    @Test("来源为空的条目不会被误匹配")
    func emptySourceNotMatched() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try IngestService(store: store).ingest(
            RawSnapshot(representations: [("public.utf8-plain-text", Data("没有来源".utf8), 0)]))
        #expect(try store.browse(source: "Chrome").isEmpty)
        #expect(try store.browse().count == 1)
    }
}

// MARK: - 版本比较

@Suite("版本比较")
struct VersionCompareTests {

    /// 与 Updater.isNewer 同一套逻辑。字符串比较会把 "0.10.0" 判成小于 "0.9.0"，
    /// 必须逐段比数字。
    private func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @Test("语义化版本逐段比较")
    func semantic() {
        #expect(isNewer("0.2.0", than: "0.1.0"))
        #expect(!isNewer("0.1.0", than: "0.1.0"))
        #expect(!isNewer("0.1.0", than: "0.2.0"))
        #expect(isNewer("1.0.0", than: "0.99.9"))
    }

    /// 这条是关键：按字符串比 "0.10.0" < "0.9.0"，会导致用户永远收不到 0.10 的更新
    @Test("两位数版本号不会被判错")
    func doubleDigit() {
        #expect(isNewer("0.10.0", than: "0.9.0"))
        #expect(isNewer("1.20.0", than: "1.3.0"))
        #expect(!isNewer("1.3.0", than: "1.20.0"))
    }

    @Test("段数不同时短的补 0")
    func differentLengths() {
        #expect(isNewer("0.1.1", than: "0.1"))
        #expect(!isNewer("0.1", than: "0.1.0"))
    }
}

// MARK: - OCR 存储与索引

@Suite("OCR 队列与索引")
struct OCRStoreTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    private func makePNG(_ w: Int, _ h: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// 图片入库要自动排队。不排队的话 OCR 永远不会发生。
    @Test("图片入库后自动进 OCR 队列")
    func imageEnqueued() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try ingest.ingest(RawSnapshot(representations: [("public.png", try makePNG(400, 300), 0)]))
        try ingest.ingest(RawSnapshot(representations: [("public.utf8-plain-text", Data("文本".utf8), 0)]))

        #expect(try store.pendingOCRCount() == 1, "只有图片该进队列")
    }

    /// OCR 文字必须并入搜索索引，否则"能搜图里的字"就是空话
    @Test("OCR 文字并入搜索索引")
    func ocrTextBecomesSearchable() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(
            RawSnapshot(representations: [("public.png", try makePNG(400, 300), 0)])))

        #expect(try store.search("服务器地址").isEmpty)

        try store.completeOCR(itemID: id,
            result: .init(text: "服务器地址 10.20.30.40 端口 8443", engine: "test", confidence: 1),
            sensitive: false)

        #expect(try store.search("服务器地址").count == 1, "OCR 文字没进索引")
        #expect(try store.search("8443").count == 1)
        #expect(try store.ocrText(for: id)?.contains("10.20.30.40") == true)
        #expect(try store.pendingOCRCount() == 0, "完成后该出队")
    }

    /// ⚠️ OCR 会把截图里的密码变成明文可搜索字符串，绕过整个敏感内容策略。
    /// 命中敏感规则时必须只存不索引。
    @Test("敏感 OCR 文字不进索引")
    func sensitiveOCRNotIndexed() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(
            RawSnapshot(representations: [("public.png", try makePNG(400, 300), 0)])))

        try store.completeOCR(itemID: id,
            result: .init(text: "password: hunter2supersecret", engine: "test", confidence: 1),
            sensitive: true)

        #expect(try store.search("hunter2supersecret").isEmpty, "敏感 OCR 文字进索引了")
        // 但结果本身要留着，预览时能看
        #expect(try store.ocrText(for: id) != nil)
    }

    @Test("放弃的任务不再重复处理")
    func giveUpRemovesFromQueue() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(
            RawSnapshot(representations: [("public.png", try makePNG(400, 300), 0)])))

        try store.failOCR(itemID: id, reason: "no-text", giveUp: true)
        #expect(try store.pendingOCRCount() == 0)
        let s = try store.ocrStats()
        #expect(s.skipped == 1)
    }

    @Test("敏感条目的图片不排队 —— 根本不该被识别")
    func sensitiveItemNotQueued() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 敏感文本条目不是图片，不会排队；这里确认队列只认图片
        try IngestService(store: store).ingest(RawSnapshot(
            representations: [("public.utf8-plain-text", Data("api_key = sk-live-abcdef123456".utf8), 0)]))
        #expect(try store.pendingOCRCount() == 0)
    }
}

// MARK: - 粘贴变换

@Suite("粘贴变换")
struct TransformTests {

    private let reg = TransformerRegistry.standard()

    @Test("JSON 识别：先形状后解析")
    func detectJSON() {
        #expect(JSONDetector.looksLikeJSON(#"{"a":1,"b":[1,2]}"#))
        #expect(JSONDetector.looksLikeJSON("[1, 2, 3]"))
        #expect(!JSONDetector.looksLikeJSON("这不是 JSON"))
        #expect(!JSONDetector.looksLikeJSON(#"{"a":1"#), "残缺 JSON 不该通过")
        // 形状对但内容非法
        #expect(!JSONDetector.looksLikeJSON("{not json}"))
    }

    @Test("JSON 格式化与压缩往返")
    func jsonRoundTrip() throws {
        let src = #"{"operateWay":"update","sql":"UPDATE t SET a=1","pretty":1}"#
        let pretty = try #require(JSONDetector.pretty(src))
        #expect(pretty.contains("\n"), "没有换行说明没格式化")
        let mini = try #require(JSONDetector.minify(pretty))
        #expect(!mini.contains("\n"))
        // 压缩回去语义要一致
        let a = JSONDetector.parse(src) as? [String: Any]
        let b = JSONDetector.parse(mini) as? [String: Any]
        #expect(a?.count == b?.count)
    }

    /// 斜杠不该被转义成 \/ —— 那会让 SQL、URL 里的路径变得难读
    @Test("格式化不转义斜杠")
    func noSlashEscaping() throws {
        let src = #"{"url":"https://example.com/a/b"}"#
        let pretty = try #require(JSONDetector.pretty(src))
        #expect(!pretty.contains(#"\/"#))
    }

    @Test("JSON 转义与反转义互逆")
    func escapeRoundTrip() throws {
        let src = "{\n  \"a\": \"x\\y\"\n}"
        let esc = try JSONEscapeTransformer().apply(to: src)
        #expect(!esc.contains("\n"))
        let back = try JSONUnescapeTransformer().apply(to: esc)
        #expect(back == src)
    }

    @Test("URL 编解码互逆，且编码 & = ? +")
    func urlRoundTrip() throws {
        let src = "a=1&b=中文 空格?x+y"
        let enc = try URLEncodeTransformer().apply(to: src)
        #expect(!enc.contains("&"))
        #expect(!enc.contains("="))
        #expect(!enc.contains(" "))
        #expect(try URLDecodeTransformer().apply(to: enc) == src)
    }

    @Test("Base64 编解码互逆")
    func base64RoundTrip() throws {
        let src = "订单支付回调 orderId=2606"
        let enc = try Base64EncodeTransformer().apply(to: src)
        #expect(try Base64DecodeTransformer().apply(to: enc) == src)
    }

    /// 不这么判的话，任何一段英文都会显示"可 Base64 解码"，然后解出乱码
    @Test("Base64 解码只在真像 Base64 时才提供")
    func base64Guard() {
        let t = Base64DecodeTransformer()
        #expect(!t.canApply(to: "这是一段普通中文"))
        #expect(!t.canApply(to: "hello world"))
        #expect(t.canApply(to: Data("hello world".utf8).base64EncodedString()))
    }

    /// 不适用的变换不该出现在菜单里
    @Test("只列出适用的变换")
    func onlyApplicable() {
        let plain = reg.applicable(to: "普通一句话", developerMode: true)
        #expect(!plain.contains { $0.id == "json.pretty" }, "非 JSON 不该出现 JSON 格式化")

        let json = reg.applicable(to: #"{"a":1}"#, developerMode: true)
        #expect(json.contains { $0.id == "json.pretty" })
        #expect(json.contains { $0.id == "json.minify" })
    }

    /// 开发者功能对普通用户完全隐形
    @Test("非开发者模式下不出现开发者变换")
    func developerGating() {
        let list = reg.applicable(to: #"{"a":1}"#, developerMode: false)
        #expect(!list.contains { $0.developerOnly }, "开发者变换泄漏给了普通模式")
        #expect(list.allSatisfy { !$0.developerOnly })
    }

    /// JSON 格式化/压缩**不归开发者开关管**。
    ///
    /// 它们的 canApply 要求内容真是合法 JSON，对普通用户天然隐形，
    /// 再藏一层开关只会让人以为功能没做 —— 实际发生过。
    @Test("JSON 格式化不需要开发者模式")
    func jsonAvailableWithoutDeveloperMode() {
        let list = reg.applicable(to: #"{"a":1,"b":[2,3]}"#, developerMode: false)
        #expect(list.contains { $0.id == "json.pretty" }, "普通模式下 JSON 格式化必须可用")
        #expect(list.contains { $0.id == "json.minify" })

        // 但普通文本不能被它污染
        let plain = reg.applicable(to: "今天天气不错", developerMode: false)
        #expect(!plain.contains { $0.group == .json })
    }

    @Test("去空行只在真有连续空行时提供")
    func trimGating() {
        let t = TrimBlankLinesTransformer()
        #expect(!t.canApply(to: "a\n\nb"))
        #expect(t.canApply(to: "a\n\n\n\nb"))
    }
}

// MARK: - 面板分栏

@Suite("左右分栏宽度")
struct SplitLayoutTests {

    private let minList = 300.0
    private let minPreview = 220.0
    private let splitter = 7.0

    private func w(total: Double, ratio: Double) -> Double {
        SplitLayout.listWidth(total: total, ratio: ratio,
                              minList: minList, minPreview: minPreview, splitter: splitter)
    }

    /// 核心诉求：窗口拉宽，两栏都要跟着变宽。
    /// 之前列表写死 380pt，拉窗口只有预览在变 —— 这条就是为了防它回来。
    @Test("面板变宽时两栏按比例同时变宽")
    func bothColumnsGrow() {
        let narrow = w(total: 720, ratio: 0.5)
        let wide   = w(total: 1200, ratio: 0.5)
        #expect(wide > narrow, "面板拉宽后列表没变宽 —— 布局又被写死了")

        let narrowPreview = 720 - splitter - narrow
        let widePreview   = 1200 - splitter - wide
        #expect(widePreview > narrowPreview)
    }

    @Test("比例正常时按比例给宽度")
    func honoursRatio() {
        let total = 1000.0
        #expect(abs(w(total: total, ratio: 0.6) - (total - splitter) * 0.6) < 0.001)
    }

    /// 拖到头不能把任何一栏压没 —— 归零的那栏用户再也拖不回来
    @Test("两侧下限都夹得住")
    func clampsBothSides() {
        let total = 900.0
        let usable = total - splitter
        #expect(w(total: total, ratio: 0.01) == minList)
        #expect(w(total: total, ratio: 0.99) == usable - minPreview)
    }

    /// 面板被拉到比两栏下限之和还窄：对半分，不让某一栏归零
    @Test("窄于两栏下限之和时对半分")
    func tooNarrowFallsBackToHalf() {
        let total = 400.0   // 400 - 7 = 393 < 300 + 220
        #expect(abs(w(total: total, ratio: 0.9) - (total - splitter) / 2) < 0.001)
        #expect(w(total: total, ratio: 0.9) > 0)
    }

    @Test("拖动换算回比例，同样受下限约束")
    func dragRatioClamped() {
        let total = 900.0
        let usable = total - splitter
        let low = SplitLayout.ratio(forListWidth: 10, total: total,
                                    minList: minList, minPreview: minPreview, splitter: splitter)
        #expect(abs((low ?? 0) - minList / usable) < 0.001)

        let high = SplitLayout.ratio(forListWidth: 5000, total: total,
                                     minList: minList, minPreview: minPreview, splitter: splitter)
        #expect(abs((high ?? 0) - (usable - minPreview) / usable) < 0.001)
    }

    /// 太窄时拖动无意义，返回 nil 而不是一个会把预览压没的比例
    @Test("面板过窄时拖动不生效")
    func dragDisabledWhenTooNarrow() {
        #expect(SplitLayout.ratio(forListWidth: 300, total: 400,
                                  minList: minList, minPreview: minPreview,
                                  splitter: splitter) == nil)
    }

    /// 存进设置的比例往返一趟要稳定，不能每次唤出都漂一点
    @Test("比例往返稳定")
    func roundTripStable() {
        let total = 1000.0
        let ratio = 0.42
        let width = w(total: total, ratio: ratio)
        let back = SplitLayout.ratio(forListWidth: width, total: total,
                                     minList: minList, minPreview: minPreview, splitter: splitter)
        #expect(abs((back ?? 0) - ratio) < 0.001)
    }
}

// MARK: - 面板摆放

@Suite("面板贴边摆放")
struct PanelPlacementTests {

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
    private let want = CGSize(width: 1000, height: 700)
    private let minSize = CGSize(width: 520, height: 320)

    private func place(_ x: CGFloat, _ y: CGFloat,
                       preferred: CGSize? = nil,
                       screen s: CGRect? = nil) -> PanelPlacement.Result {
        PanelPlacement.place(mouse: CGPoint(x: x, y: y),
                             preferred: preferred ?? want,
                             minSize: minSize,
                             visible: s ?? screen)
    }

    @Test("空间充足：原尺寸、开右下、不镜像")
    func roomy() {
        let r = place(200, 900)
        #expect(r.frame.size == want)
        #expect(!r.mirrored)
        #expect(r.frame.minX > 200)          // 在鼠标右边
        #expect(r.frame.maxY < 900)          // 在鼠标下边
    }

    /// 这条是这次改动的核心诉求：
    /// 右边放不下完整宽度，但还够摆一个像样的面板 —— 缩宽度，**不要翻到另一边**。
    @Test("贴右边但空间还够：缩宽度而不镜像")
    func shrinkInsteadOfMirror() {
        let r = place(1000, 900)             // 右侧剩 1800-1000-8 = 792 < 1000
        #expect(!r.mirrored, "空间还够 792pt 就翻到另一边了 —— 布局会左右对调，很打断人")
        #expect(r.frame.width == 792)
        #expect(r.frame.maxX <= screen.maxX)
    }

    /// 缩到偏好宽度 60% 以下就不值得再缩，宁可翻过去保持完整
    @Test("太贴右边：翻到左侧并保持完整宽度")
    func mirrorWhenTooTight() {
        let r = place(1500, 900)             // 右侧只剩 292，低于 max(520, 600)
        #expect(r.mirrored)
        #expect(r.frame.width == want.width)
        #expect(r.frame.maxX <= 1500)        // 整个面板在鼠标左边
    }

    @Test("纵向同样先缩高度再往上开")
    func shrinkHeight() {
        let r = place(200, 600)              // 下方剩 592 < 700，但 > max(320, 420)
        #expect(r.frame.height == 592)
        #expect(r.frame.minY >= 0)
    }

    @Test("太贴底部：改为向上展开并保持完整高度")
    func flipUp() {
        let r = place(200, 300)              // 下方只剩 292
        #expect(r.frame.height == want.height)
        #expect(r.frame.minY >= 300)         // 在鼠标上方
    }

    /// 屏幕比面板还小时不能溢出 —— 这是最容易漏的一档
    @Test("屏幕比面板小：钳进屏幕内")
    func tinyScreen() {
        let small = CGRect(x: 0, y: 0, width: 700, height: 500)
        for x in stride(from: 0.0, through: 700.0, by: 100.0) {
            for y in stride(from: 0.0, through: 500.0, by: 100.0) {
                let r = place(x, y, screen: small)
                #expect(small.contains(r.frame), "鼠标 (\(x),\(y)) 时面板跑出屏幕：\(r.frame)")
            }
        }
    }

    /// 非原点屏幕（外接显示器常见负坐标）也必须落在可见区内
    @Test("外接屏负坐标下也不跑出去")
    func offsetScreen() {
        let ext = CGRect(x: -393, y: -1440, width: 2560, height: 1440)
        for x in stride(from: -393.0, through: 2167.0, by: 320.0) {
            for y in stride(from: -1440.0, through: 0.0, by: 240.0) {
                let r = place(x, y, screen: ext)
                #expect(ext.contains(r.frame), "鼠标 (\(x),\(y)) 时面板跑出屏幕：\(r.frame)")
            }
        }
    }

    /// 尺寸永远不该小于下限（除非屏幕本身就更小）
    @Test("任何位置都不小于最小尺寸")
    func neverBelowMin() {
        for x in stride(from: 0.0, through: 1800.0, by: 150.0) {
            for y in stride(from: 0.0, through: 1100.0, by: 150.0) {
                let r = place(x, y)
                #expect(r.frame.width >= minSize.width, "鼠标 x=\(x) 时宽度 \(r.frame.width)")
                #expect(r.frame.height >= minSize.height, "鼠标 y=\(y) 时高度 \(r.frame.height)")
            }
        }
    }
}

// MARK: - 设置解码容错

@Suite("设置解码")
struct SettingsDecodingTests {

    /// ⚠️ 回归测试：这条挂过两次。
    ///
    /// Swift 合成的 Decodable 对缺失的非可选字段直接抛 keyNotFound，**不会**回退到默认值；
    /// 而 `load()` 用 `try?` 吞异常后返回全默认值 —— 于是**每加一个设置字段，
    /// 用户已存的所有设置被静默清空**（面板尺寸、分栏比例、开发者模式一起回出厂）。
    @Test("老版本存的设置缺新字段时，其余字段必须保住")
    func missingFieldKeepsOthers() throws {
        // 模拟"加 previewSplitRatio 之前"存下来的 JSON：没有这个键
        let old = """
        {"retention":30,"sensitiveTTL":600,"maxItems":0,"maxStorageMB":4096,
         "maxItemSizeMB":50,"excludedBundleIDs":["com.x.y"],"captureOnStart":true,
         "autoCheckUpdates":false,"enableOCR":false,"panelWidth":896,"panelHeight":965,
         "splitRatio":0.41,"uiScale":1.15,"developerMode":true}
        """
        let s = try JSONDecoder().decode(ClipflowSettings.self, from: Data(old.utf8))

        #expect(s.panelWidth == 896, "加字段把用户的面板尺寸清了")
        #expect(s.panelHeight == 965)
        #expect(abs(s.splitRatio - 0.41) < 0.0001)
        #expect(s.developerMode == true)
        #expect(s.uiScale == 1.15)
        #expect(s.maxStorageMB == 4096)
        #expect(s.enableOCR == false)
        #expect(s.excludedBundleIDs == ["com.x.y"])
        // 缺失的新字段回落到默认值，而不是让整次解码失败
        #expect(s.previewSplitRatio == ClipflowSettings().previewSplitRatio)
    }

    @Test("完全空的 JSON 也能解出全默认值，不抛异常")
    func emptyObjectDecodes() throws {
        let s = try JSONDecoder().decode(ClipflowSettings.self, from: Data("{}".utf8))
        #expect(s == ClipflowSettings())
    }

    @Test("往返编解码保真")
    func roundTrip() throws {
        var s = ClipflowSettings()
        s.panelWidth = 1234
        s.splitRatio = 0.37
        s.previewSplitRatio = 0.62
        s.developerMode = true
        let back = try JSONDecoder().decode(ClipflowSettings.self,
                                            from: try JSONEncoder().encode(s))
        #expect(back == s)
    }
}

// MARK: - SQL 识别

@Suite("SQL 识别")
struct SQLDetectorTests {

    @Test("常见语句都能认出来")
    func positives() {
        let cases = [
            "SELECT * FROM users WHERE id = 1",
            "select id, name from t_order where status = 5 and is_delete = 0",
            "UPDATE TrainOrder202607 SET Status = 11, StatusName = '已退款' WHERE OrderID = 'X'",
            "INSERT INTO `FormEngineDB`.`FormConfig0` (a, b) VALUES (1, 2)",
            "DELETE FROM logs WHERE created_at < '2026-01-01'",
            "CREATE TABLE t (id INT PRIMARY KEY, name VARCHAR(64))",
            "ALTER TABLE t ADD COLUMN c INT",
            "DROP INDEX idx_a ON t",
            "TRUNCATE TABLE staging",
            "WITH x AS (SELECT 1 AS a) SELECT * FROM x",
            "EXPLAIN SELECT * FROM t",
            "-- 上线前跑一遍\nSELECT count(*) FROM orders",
            "/* 批量修数 */ UPDATE t SET a = 1 WHERE b = 2",
            "SELECT 1 WHERE 1 = 1",
        ]
        for c in cases {
            #expect(SQLDetector.looksLikeSQL(c), "没认出来：\(c.prefix(40))")
        }
    }

    /// 光看首关键字会把这些全误判成 SQL —— 必配子句这一层就是防它们的
    @Test("像 SQL 的英文/中文句子不能误判")
    func negatives() {
        let cases = [
            "Update the docs before you ship",
            "select 一下这个方案再定",
            "Delete these files when you get a chance",
            "创建一个新的分组",
            "insert coin to continue",
            "drop me a message",
            "SELECT",
            "",
            "https://github.com/TomEageer/clipflow",
            #"{"sql": "SELECT * FROM t"}"#,          // 是 JSON 不是 SQL
            "let rows = db.select(from: table)",     // 首词不是关键字
        ]
        for c in cases {
            #expect(!SQLDetector.looksLikeSQL(c), "误判成 SQL：\(c.prefix(40))")
        }
    }

    /// 括号/引号不配平说明这段是被截断或抠错了，不该算"结构合法"
    @Test("括号引号不配平判不通过")
    func unbalanced() {
        #expect(!SQLDetector.looksLikeSQL("SELECT * FROM t WHERE a IN (1, 2"))
        #expect(!SQLDetector.looksLikeSQL("SELECT * FROM t WHERE name = 'abc"))
        #expect(!SQLDetector.looksLikeSQL("INSERT INTO t (a, b VALUES (1, 2)"))
    }

    /// 字符串字面量里的括号不算数，转义引号也要认
    @Test("引号内的括号与转义引号不影响配平")
    func quoteAware() {
        #expect(SQLDetector.looksLikeSQL("SELECT * FROM t WHERE name = '张三)'"))
        #expect(SQLDetector.looksLikeSQL("UPDATE t SET a = 'it''s ok' WHERE b = 1"))
        #expect(SQLDetector.looksLikeSQL("SELECT * FROM `db`.`tbl` WHERE x = \"a(b\""))
    }

    /// 整词匹配：FORMAT 里含 FROM 之类不能算命中
    @Test("伴随关键字必须整词匹配")
    func wholeWordOnly() {
        #expect(!SQLDetector.looksLikeSQL("SELECT FORMATTED VALUES"))
        #expect(SQLDetector.looksLikeSQL("SELECT a FROM b"))
    }
}

// MARK: - Shell 命令识别

@Suite("Shell 命令识别")
struct ShellDetectorTests {

    @Test("常见命令都能认出来")
    func positives() {
        let cases = [
            "curl -X POST https://api.example.com/v1/orders -H 'Content-Type: application/json'",
            "$ curl -sL https://example.com | sh",
            "git commit -m \"fix: 修一下\"",
            "docker run --rm -it ubuntu bash",
            "npm install --save-dev vite",
            "brew install ffmpeg",
            "ssh tom@154.36.173.132",
            "sudo systemctl restart nginx",
            "#!/bin/bash\necho hi",
            "# 先装依赖\nnpm ci",
            "kubectl get pods -n prod",
            "python3 -m venv .venv",
            "find . -name '*.swift'",
            "rm -rf build/",
        ]
        for c in cases {
            #expect(ShellDetector.looksLikeShell(c), "没认出来：\(c.prefix(40))")
        }
    }

    /// 弱命令词在中英文句子里太常见，只看首词必然误判 —— 所以要求有选项或路径
    @Test("像命令的自然语句不能误判")
    func negatives() {
        let cases = [
            "find 一下这个文件在哪",
            "open the door",
            "cat 很可爱",
            "echo 这个词的意思是回声",
            "git",                       // 只有命令名，没参数
            "docker",
            "今天要 make 一个决定",
            "SELECT * FROM users",       // 是 SQL 不是 shell
            "",
        ]
        for c in cases {
            #expect(!ShellDetector.looksLikeShell(c), "误判成命令：\(c.prefix(40))")
        }
    }

    @Test("引号不配平判不通过（多半是被截断了）")
    func unbalanced() {
        #expect(!ShellDetector.looksLikeShell("curl -H 'Content-Type: application/json"))
        #expect(ShellDetector.looksLikeShell("curl -d \"a=1\" https://x.com"))
        // 转义引号不算配对
        #expect(ShellDetector.looksLikeShell("git commit -m \"say \\\"hi\\\"\""))
    }

    @Test("curl 能被单独认出来")
    func curl() {
        #expect(ShellDetector.looksLikeCurl("curl https://example.com"))
        #expect(ShellDetector.looksLikeCurl("$ sudo curl -O https://x.com/a.zip"))
        #expect(!ShellDetector.looksLikeCurl("git push origin main"))
    }
}

// MARK: - 本地化

@Suite("本地化词表")
struct LocalizationTests {

    private func strings(_ target: String, _ lang: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Sources/\(target)/Resources/\(lang).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.range(of: "=") else { continue }
            let k = line[line.startIndex..<eq.lowerBound]
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let v = line[eq.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !k.isEmpty, !k.hasPrefix("/*") { out[k] = v }
        }
        return out
    }

    /// 两种语言的词表必须**键完全一致**。
    /// 缺键时 `localizedString(forKey:value:)` 会把 key 原样显示出来 ——
    /// 界面上会冒出 "panel.key.paste" 这种东西，而且不会有任何报错。
    @Test("中英词表的键必须一一对应", arguments: ["ClipflowApp", "ClipflowCore"])
    func keysMatch(target: String) throws {
        let zh = try strings(target, "zh-Hans")
        let en = try strings(target, "en")
        #expect(!zh.isEmpty)
        let missingEN = Set(zh.keys).subtracting(en.keys).sorted()
        let missingZH = Set(en.keys).subtracting(zh.keys).sorted()
        #expect(missingEN.isEmpty, "\(target) 英文缺键：\(missingEN)")
        #expect(missingZH.isEmpty, "\(target) 中文缺键：\(missingZH)")
    }

    /// 带 %d / %@ 占位符的条目，两种语言的占位符数量必须一致 ——
    /// 少一个就是 `String(format:)` 读到野指针，多一个就是崩溃。
    @Test("格式化占位符数量一致", arguments: ["ClipflowApp", "ClipflowCore"])
    func placeholdersMatch(target: String) throws {
        let zh = try strings(target, "zh-Hans")
        let en = try strings(target, "en")
        func count(_ s: String) -> Int {
            s.components(separatedBy: "%").count - 1 - (s.components(separatedBy: "%%").count - 1) * 2
        }
        for (k, v) in zh {
            guard let e = en[k] else { continue }
            #expect(count(v) == count(e), "\(target) [\(k)] 占位符数量不一致：中「\(v)」英「\(e)」")
        }
    }
}

// MARK: - 图片 vs 文件引用

@Suite("图片与文件引用的判定")
struct ImageVsFileRefTests {

    private func classify(_ reps: [(String, Data)]) -> ClipKind? {
        var snap = RawSnapshot(representations: reps.map { ($0.0, $0.1, 0) })
        var ctx = IngestContext()
        _ = TypeClassifier().process(&snap, context: &ctx)
        return ctx.kind
    }

    /// ⚠️ 回归测试：微信复制图片曾被标成「文件」。
    ///
    /// 不少 App 复制图片时会**同时**给一个指向临时文件的 file-url 和真正的图片数据。
    /// 先判 file-url 的话这条就成了「文件」，预览是一长串路径 ——
    /// 而那个路径在 App 自己的容器里，迟早被清掉。图片数据才是本体。
    @Test("同时有 file-url 和图片数据时，算图片")
    func imageWinsOverFileURL() {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 64))
        let url = Data("file://localhost/tmp/RWTemp/x.jpg".utf8)
        #expect(classify([("public.file-url", url), ("public.tiff", png)]) == .image)
        #expect(classify([("public.tiff", png), ("public.file-url", url)]) == .image)
    }

    /// 反过来：访达里复制一张 .jpg 只给 file-url、没有图片数据，那它就该是文件。
    /// 判据是「有没有图片数据」，不是「是不是图片文件」。
    @Test("只有 file-url 时仍算文件")
    func fileURLAloneIsFile() {
        let url = Data("file:///Users/tom/Desktop/photo.jpg".utf8)
        #expect(classify([("public.file-url", url)]) == .fileRef)
    }

    @Test("只有图片数据时算图片")
    func imageAlone() {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 64))
        #expect(classify([("public.png", png)]) == .image)
    }
}

// MARK: - 编辑原文后落盘

@Suite("编辑原文")
struct EditOriginalTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    /// 改完之后：内容变了、能搜到新词、搜不到旧词。
    @Test("改写文本后内容与索引都更新")
    func updateTextPersists() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(
            RawSnapshot(representations: [("public.utf8-plain-text", Data("订单支付回调".utf8), 0)])))

        #expect(try store.search("订单支付").count == 1)

        try store.updateText("退款流程说明", itemID: id)

        let reps = try store.representations(of: id)
        let rep = try #require(reps.first)
        let d = try #require(try store.data(of: rep))
        #expect(String(data: d, encoding: .utf8) == "退款流程说明")
        #expect(try store.search("退款流程").count == 1)
        #expect(try store.search("订单支付").isEmpty, "旧内容还能搜到 —— 索引没重建")
        #expect(try store.recent().first?.preview == "退款流程说明")
    }

    /// ⚠️ 富文本表示必须删掉。
    /// 只改 plain 的话，粘出去时接收方多半取 html/rtf 那份 ——
    /// 用户看到的还是改之前的内容，会以为"编辑没生效"。
    @Test("改写后不再保留过期的富文本表示")
    func staleRichTextDropped() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(RawSnapshot(representations: [
            ("public.utf8-plain-text", Data("原来的字".utf8), 0),
            ("public.html", Data("<b>原来的字</b>".utf8), 0),
        ])))
        #expect(try store.representations(of: id).count == 2)

        try store.updateText("改过的字", itemID: id)

        let reps = try store.representations(of: id)
        #expect(reps.count == 1)
        #expect(reps.first?.uti == "public.utf8-plain-text")
    }

    /// 指纹要跟着变，否则日后再复制**原始那段**内容会命中这条 ——
    /// 表现为"复制 A，粘出来是改过的 B"。
    @Test("改写后重新复制原内容不会命中这条")
    func hashRecomputed() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let snap = RawSnapshot(representations: [("public.utf8-plain-text", Data("原始内容".utf8), 0)])
        let id = try #require(try ingest.ingest(snap))
        try store.updateText("改过之后", itemID: id)

        let again = try #require(try ingest.ingest(snap))
        #expect(again != id, "重新复制原内容命中了已被改写的那条")
        #expect(try store.count() == 2)
    }

    /// 把 JSON 改坏之后就不该再挂着 JSON 标签
    @Test("类型跟着内容重判")
    func kindReclassified() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        let id = try #require(try ingest.ingest(
            RawSnapshot(representations: [("public.utf8-plain-text", Data(#"{"a":1}"#.utf8), 0)])))
        #expect(try store.recent().first?.kind == .json)

        try store.updateText("就是一句普通的话", itemID: id)
        #expect(try store.recent().first?.kind == .text)
    }
}

// MARK: - 搜索排序

@Suite("搜索排序")
struct SearchRankingTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    private func put(_ ingest: IngestService, _ text: String) throws {
        try ingest.ingest(RawSnapshot(representations: [("public.utf8-plain-text", Data(text.utf8), 0)]))
    }

    @Test("分层：全匹配 > 前缀 > 全模糊")
    func tiers() throws {
        #expect(SearchRanker.tier(query: "user", name: nil, preview: "user") == .titleExact)
        #expect(SearchRanker.tier(query: "user", name: nil, preview: "userName") == .titlePrefix)
        #expect(SearchRanker.tier(query: "user", name: nil, preview: "/Users/tom") == .fuzzy)
        #expect(SearchRanker.tier(query: "user", name: "user", preview: "随便") == .nameExact)
        #expect(SearchRanker.tier(query: "user", name: "userInfo", preview: "随便") == .namePrefix)
        // 大小写不参与判定
        #expect(SearchRanker.tier(query: "select", name: nil, preview: "SELECT *") == .titlePrefix)
        // 标题是首个非空行，不是整段
        #expect(SearchRanker.tier(query: "select", name: nil, preview: "\n\n  select * from t\nx") == .titlePrefix)
    }

    /// 用户报的原始症状：搜 user 全是路径里含 /Users/ 的，想要的 userName 一条都看不到。
    @Test("前缀命中排在模糊命中前面")
    func prefixBeatsFuzzy() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try put(ingest, "userName")                 // 前缀命中，最早
        for i in 0..<30 { try put(ingest, "/Users/tom/path/\(i)") }   // 模糊命中，更近

        let hits = try store.search("user", limit: 50)
        #expect(hits.first?.preview == "userName")
        #expect(hits.count == 31)                   // 模糊命中一条不少，只是排后面
    }

    @Test("同一层内按最近优先")
    func recentFirstWithinTier() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try put(ingest, "userA")
        try put(ingest, "userB")
        try put(ingest, "userC")

        let hits = try store.search("user", limit: 10)
        #expect(hits.map(\.preview) == ["userC", "userB", "userA"])
    }

    /// 锚定命中必须单独查库。只从 FTS 的「最近 N 条命中」里挑，
    /// 一条老的精确匹配会被新的模糊命中挤出候选集 —— 这就是「老是查不出来」。
    @Test("老的精确匹配不会被新的模糊命中挤掉")
    func oldExactSurvivesTruncation() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try put(ingest, "token")
        for i in 0..<300 { try put(ingest, "这里有个 token 在中间 \(i)") }

        let hits = try store.search("token", limit: 20)
        #expect(hits.first?.preview == "token")
    }

    @Test("分类过滤走 SQL，不会因候选截断而空白")
    func kindFilterInSQL() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)

        try ingest.ingest(RawSnapshot(representations: [("public.file-url", Data("file:///abc/token.txt".utf8), 0)]))
        for i in 0..<250 { try put(ingest, "token \(i)") }

        let files = try store.search("token", limit: 20, kinds: [.fileRef])
        #expect(files.count == 1)
        #expect(files.first?.kind == .fileRef)
    }

    @Test("LIKE 通配符被转义：搜 100% 不等于搜以 100 开头")
    func escapesLikeWildcards() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try put(ingest, "100%")
        try put(ingest, "1000 元")

        let hits = try store.search("100%", limit: 10)
        // "1000 元" 仍会作为模糊命中出现 —— FTS 的 unicode61 把 % 当标点剥掉了，
        // 这是分词器的既定行为。转义保证的是它**不被算成前缀命中**排到前面去。
        #expect(hits.first?.preview == "100%")
        #expect(SearchRanker.tier(query: "100%", name: nil, preview: "1000 元") == .fuzzy)
    }
}

// MARK: - preview 是摘要不是全文

@Suite("preview 与索引的分工")
struct PreviewAndIndexTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    @Test("preview 被裁到上限，全文仍可取回")
    func previewIsBounded() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "甲", count: ClipItem.previewLimit * 3)
        try IngestService(store: store).ingest(
            RawSnapshot(representations: [("public.utf8-plain-text", Data(long.utf8), 0)]))

        let item = try #require(try store.recent(limit: 1).first)
        #expect(item.preview.count == ClipItem.previewLimit)
        let id = try #require(item.id)
        #expect(store.plainText(of: id)?.count == long.count)
    }

    /// preview 收敛成摘要之后，索引必须从**全文**建 ——
    /// 否则超过 2000 字的内容，后半截会悄无声息地搜不到。
    @Test("索引建在全文上，超出 preview 的部分也能搜到")
    func indexesFullText() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "甲", count: ClipItem.previewLimit) + "尾部暗号"
        try IngestService(store: store).ingest(
            RawSnapshot(representations: [("public.utf8-plain-text", Data(long.utf8), 0)]))

        #expect(try store.search("尾部暗号", limit: 10).count == 1)
    }

    /// 改名走的是同一个建索引入口。要是它按 preview 重建，
    /// 一次改名就会把这条的可搜范围砍到前 2000 字。
    @Test("改名不会砍掉正文的可搜范围")
    func renameKeepsFullTextSearchable() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "乙", count: ClipItem.previewLimit) + "尾部暗号"
        try IngestService(store: store).ingest(
            RawSnapshot(representations: [("public.utf8-plain-text", Data(long.utf8), 0)]))
        let id = try #require(try store.recent(limit: 1).first?.id)

        try store.setName("我的备注", itemID: id)

        #expect(try store.search("尾部暗号", limit: 10).count == 1)
        #expect(try store.search("我的备注", limit: 10).count == 1)
    }
}

// MARK: - 搜索精度

@Suite("搜索精度")
struct SearchPrecisionTests {

    private func tempStore() throws -> (ClipflowStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "clipflow-test-\(UUID().uuidString)")
        return (try ClipflowStore(paths: StoragePaths(root: dir)), dir)
    }

    private func put(_ ingest: IngestService, _ text: String) throws {
        try ingest.ingest(RawSnapshot(representations: [("public.utf8-plain-text", Data(text.utf8), 0)]))
    }

    /// 用户报的：搜 test 命中了这条 SQL。
    /// 旧实现逐字符入索引，标点被 unicode61 丢掉又不占位置，
    /// `update` 的尾巴接 `Staff` 的头拼出了 `t e s t`。
    @Test("不跨词拼出假命中")
    func noCrossWordFalsePositive() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try put(ingest, "update `StaffInfo12` SET leaderStaffNo = '' WHERE `KeyID` = 'x' limit 1;")

        #expect(try store.search("test", limit: 10).isEmpty)
        #expect(try store.search("ates", limit: 10).isEmpty)
        // 真正出现过的词仍要搜得到
        #expect(try store.search("update", limit: 10).count == 1)
        #expect(try store.search("staff", limit: 10).count == 1)   // camelCase 子词
    }

    @Test("英文用前缀匹配：user 能找到 userName 和 /Users/")
    func latinPrefixMatching() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try put(ingest, "userName")
        try put(ingest, "/Users/tom/projects")
        try put(ingest, "abuser")          // 词中间含 user，不该命中

        let hits = try store.search("user", limit: 10).map(\.preview)
        #expect(hits.contains("userName"))
        #expect(hits.contains("/Users/tom/projects"))
        #expect(hits.contains("abuser") == false)
    }

    @Test("中文短语查询不退化成 AND")
    func chinesePhrase() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try put(ingest, "订单支付回调")
        try put(ingest, "这里有订单，那里有支付")   // 两词都在但不相邻

        let hits = try store.search("订单支付", limit: 10).map(\.preview)
        #expect(hits == ["订单支付回调"])
    }

    @Test("重建索引后结果不变")
    func rebuildIsIdempotent() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ingest = IngestService(store: store)
        try put(ingest, "userName")
        try put(ingest, "订单支付回调")

        let before = try store.search("user", limit: 10).map(\.preview)
        #expect(try store.rebuildIndex() == 2)
        #expect(try store.search("user", limit: 10).map(\.preview) == before)
        #expect(try store.search("订单支付", limit: 10).count == 1)
    }
}
