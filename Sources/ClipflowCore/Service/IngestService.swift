import Foundation

/// 一次剪贴板快照的原始形态：一组 (UTI, 数据)。
///
/// **必须全量捕获**，不能只取字符串 —— 一次复制是一个 NSPasteboardItem 上挂的
/// 多个 representation（public.rtf / public.html / public.utf8-plain-text / …），
/// 要「粘回去和原来一模一样」就得原样存、原样写回。
public struct RawSnapshot: Sendable {
    /// `itemIndex` = 该格式属于剪贴板上的第几个 NSPasteboardItem。
    /// 复制多个文件时会有多个 item，**不能拍平**，否则写回只剩一个。
    public var representations: [(uti: String, data: Data, itemIndex: Int)]
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var windowTitle: String?
    public var capturedAt: Date

    public init(representations: [(uti: String, data: Data, itemIndex: Int)],
                sourceBundleID: String? = nil,
                sourceAppName: String? = nil,
                windowTitle: String? = nil,
                capturedAt: Date = Date()) {
        self.representations = representations
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
    }
}

public enum IngestDecision: Sendable, Equatable {
    case accept
    case drop(reason: String)
}

/// 入库管道的可插拔处理器（拓展点 ①）。
/// 闭源模块只需实现此协议并 register()，不改核心一行。
public protocol IngestProcessor: Sendable {
    var identifier: String { get }
    func process(_ snapshot: inout RawSnapshot, context: inout IngestContext) -> IngestDecision
}

public struct IngestContext: Sendable {
    public var kind: ClipKind = .other
    public var sensitivity: Sensitivity = .normal
    public var preview: String = ""
    public var notes: [String] = []
}

/// 处理器注册表 —— D7 定的三个注册点之一。
public final class ProcessorRegistry: @unchecked Sendable {
    private var processors: [IngestProcessor] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ p: IngestProcessor) {
        lock.lock(); defer { lock.unlock() }
        processors.append(p)
    }

    public var all: [IngestProcessor] {
        lock.lock(); defer { lock.unlock() }
        return processors
    }
}

// MARK: - 入库服务

public struct IngestService: Sendable {

    private let store: ClipflowStore
    private let registry: ProcessorRegistry

    public init(store: ClipflowStore, registry: ProcessorRegistry = .defaultRegistry()) {
        self.store = store
        self.registry = registry
    }

    @discardableResult
    public func ingest(_ snapshot: RawSnapshot) throws -> Int64? {
        var snap = snapshot
        var ctx = IngestContext()

        for p in registry.all {
            if case .drop = p.process(&snap, context: &ctx) {
                return nil
            }
        }
        guard !snap.representations.isEmpty else { return nil }

        // 全部 representation 合并算指纹，用于去重
        var hasher = Data()
        for r in snap.representations.sorted(by: { ($0.itemIndex, $0.uti) < ($1.itemIndex, $1.uti) }) {
            hasher.append(r.uti.data(using: .utf8) ?? Data())
            hasher.append(r.data)
        }
        let contentHash = BlobStore.hash(hasher)
        let totalBytes = snap.representations.reduce(0) { $0 + $1.data.count }

        let item = ClipItem(
            contentHash: contentHash,
            kind: ctx.kind,
            sensitivity: ctx.sensitivity,
            preview: ctx.preview,
            createdAt: snap.capturedAt,
            lastUsedAt: snap.capturedAt,
            sourceBundleID: snap.sourceBundleID,
            sourceAppName: snap.sourceAppName,
            windowTitle: snap.windowTitle,
            byteSize: totalBytes
        )

        // < 512B 内联；≥ 512B 压缩后进 CAS
        var reps: [Representation] = []
        for r in snap.representations {
            if r.data.count < Compressor.threshold {
                reps.append(Representation(itemID: 0, itemIndex: r.itemIndex, uti: r.uti,
                                           inlineData: r.data, byteSize: r.data.count))
            } else if let packed = Compressor.compress(r.data) {
                // 压不动就存原始，别为负收益的压缩付解压成本
                let useCompressed = packed.count < r.data.count
                let payload = useCompressed ? packed : r.data
                let hash = try store.blobs.put(payload)
                reps.append(Representation(itemID: 0, itemIndex: r.itemIndex, uti: r.uti,
                                           blobHash: hash,
                                           codec: useCompressed ? .lzfse : .none,
                                           byteSize: r.data.count))
            } else {
                let hash = try store.blobs.put(r.data)
                reps.append(Representation(itemID: 0, itemIndex: r.itemIndex, uti: r.uti,
                                           blobHash: hash, codec: .none, byteSize: r.data.count))
            }
        }

        return try store.insert(item: item, representations: reps)
    }
}
