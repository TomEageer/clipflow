import Foundation
import GRDB

/// 条目类型。按「剪贴板实际给了我们什么」分，不按用户直觉的文件类型分。
public enum ClipKind: Int, Codable, Sendable, CaseIterable, DatabaseValueConvertible, Comparable {
    case text = 0
    case richText = 1
    case url = 2
    case image = 3
    case fileRef = 4        // public.file-url —— 剪贴板天生只给路径（实测 200MB 视频 = 76 字节）
    case color = 5
    case code = 6
    case other = 99

    /// 供表格按列排序用
    public static func < (a: ClipKind, b: ClipKind) -> Bool { a.label < b.label }

    public var label: String {
        switch self {
        case .text: return "文本"
        case .richText: return "富文本"
        case .url: return "链接"
        case .image: return "图片"
        case .fileRef: return "文件"
        case .color: return "颜色"
        case .code: return "代码"
        case .other: return "其他"
        }
    }
}

/// 敏感等级。决定加密与 TTL 策略（见 docs/01 §5）。
public enum Sensitivity: Int, Codable, Sendable, DatabaseValueConvertible {
    case normal = 0
    /// token / 密码 / 密钥 —— 单独加密、不入索引、短 TTL
    case sensitive = 1
}

/// 一次复制 = 一个 ClipItem，下挂多个 Representation。
public struct ClipItem: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "items"

    public var id: Int64?
    /// 全部 representation 合并后的内容指纹，用于去重
    public var contentHash: String
    public var kind: ClipKind
    public var sensitivity: Sensitivity
    /// 供列表展示与检索的纯文本摘要（图片则为 OCR 前的占位）
    public var preview: String
    public var createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    /// 单调递增的"最近使用"序号。列表排序用它而不是 lastUsedAt ——
    /// 同一毫秒内的多次写入时间戳相同，排序会变成未定义。
    public var usedSeq: Int64
    public var pinned: Bool
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// 需要 Accessibility 权限，沙盒下可能拿不到 —— 拿不到就留空，不阻塞入库
    public var windowTitle: String?
    public var byteSize: Int

    public init(
        id: Int64? = nil,
        contentHash: String,
        kind: ClipKind,
        sensitivity: Sensitivity = .normal,
        preview: String,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        useCount: Int = 0,
        usedSeq: Int64 = 0,
        pinned: Bool = false,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        windowTitle: String? = nil,
        byteSize: Int = 0
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.sensitivity = sensitivity
        self.preview = preview
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.usedSeq = usedSeq
        self.pinned = pinned
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.windowTitle = windowTitle
        self.byteSize = byteSize
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// 表格排序用的非可选来源名。KeyPathComparator 对可选值的排序语义不直观，
    /// 给一个确定的字符串更可控。
    public var sourceLabel: String { sourceAppName ?? sourceBundleID ?? "" }
}

/// 一个 representation = 剪贴板上的一种格式（public.rtf / public.html / public.png …）。
///
/// 实测：一次富文本复制会同时产生 plain + html + rtf 三份 = 原文的 3.44 倍。
/// 这是「1M 变 3M」的真凶，靠 LZFSE 压缩降到 1.27 倍。
public struct Representation: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "representations"

    public var id: Int64?
    public var itemID: Int64
    /// 该 representation 属于剪贴板上的第几个 NSPasteboardItem。
    ///
    /// **必须保留这个结构**：复制多个文件时剪贴板上是多个 item，每个挂一个
    /// public.file-url。若拍平成一个列表，写回时同一 UTI 反复 setData 后者覆盖前者，
    /// 三个文件只剩一个。实测验证过：原生写法 readObjects 得到 2 个 URL，
    /// 拍平写法只得到 1 个。
    public var itemIndex: Int
    /// UTI，如 public.utf8-plain-text / public.rtf / public.png
    public var uti: String
    /// < 512B 直接内联（实测 120B 文本压缩后仍 97.5%，压了白压）
    public var inlineData: Data?
    /// ≥ 512B 外置到 CAS，此处存 SHA-256
    public var blobHash: String?
    public var codec: Codec
    /// 原始未压缩字节数
    public var byteSize: Int

    public enum Codec: String, Codable, Sendable, DatabaseValueConvertible {
        case none
        case lzfse
    }

    public init(id: Int64? = nil, itemID: Int64, itemIndex: Int = 0, uti: String,
                inlineData: Data? = nil, blobHash: String? = nil,
                codec: Codec = .none, byteSize: Int) {
        self.id = id
        self.itemID = itemID
        self.itemIndex = itemIndex
        self.uti = uti
        self.inlineData = inlineData
        self.blobHash = blobHash
        self.codec = codec
        self.byteSize = byteSize
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
