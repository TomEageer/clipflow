import Foundation

/// 剪贴板类型读取策略。
///
/// ## 为什么需要这个东西
///
/// 实测（全新进程，跨进程读，避开缓存）：
/// ```
/// public.utf8-plain-text                0.3ms   1720B
/// public.rtf                            0.1ms   1728B
/// public.utf16-external-plain-text  23785.0ms   nil    ← badPasteboardFlavorErr (-25133)
/// ```
///
/// **只要剪贴板上有 RTF，macOS 就会广告一个谁都兑现不了的
/// `public.utf16-external-plain-text`。** 首次读它要等系统超时（实测 18.5~23.8 秒，不固定），
/// 最终返回 nil。三种写入方式全部复现，包括 **`NSAttributedString`**
/// —— 那是 TextEdit / 浏览器 / 飞书文档复制富文本的标准写法。
/// 也就是说这不是畸形用例，是**任何带格式的复制都会踩**。
///
/// ## 为什么不能靠"提前检测"
///
/// - `availableType(from:)` 对这个类型返回"可用"（0.0ms）—— **它撒谎**，筛不掉
/// - Carbon 的 flavor flags 全是 `None` —— 没有 Promised / SystemTranslated 标记可依据
/// - Carbon 底层 `PasteboardCopyItemFlavorData` 同样阻塞 18.4 秒
///
/// 系统自己的 `readObjects(forClasses:)` 只要 14ms —— 因为它**根本不枚举广告类型**，
/// 只按固定白名单取。这就是本策略的思路来源。
///
/// ## 三级策略
///
/// | 级别 | 处理 | 理由 |
/// |---|---|---|
/// | 可信 | 直接读，**不设超时** | 覆盖 99% 保真需求且从不阻塞；大图合法耗时可能超阈值，设超时反而误伤 |
/// | 已知坏 | 直接跳过 | 种子列表，零成本 |
/// | 未知 | 看门狗 + 失败记入**负缓存** | 保住冷门 App 私有格式的保真；未知坏类型每会话最多付一次超时 |
public enum TypePolicy {

    /// 可信类型：读它们从不阻塞，直接读、不设看门狗。
    /// （给大图留出合法耗时空间 —— 一张 3.8MB 图的读取可能超过任何短阈值。）
    public static let trusted: Set<String> = [
        // 文本
        "public.utf8-plain-text",
        "public.plain-text",
        "public.text",
        "public.rtf",
        "public.html",
        "public.rtfd",
        "com.apple.flat-rtfd",
        // 图片
        "public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif",
        "com.compuserve.gif", "public.svg-image", "com.adobe.pdf",
        // 文件与链接
        "public.file-url", "public.url", "public.url-name",
        // 其它常见
        "public.utf8-tab-separated-values-text",
        "public.comma-separated-values-text",
        "com.apple.finder.node",
        "com.apple.pasteboard.promised-file-url",
    ]

    /// 已知不可兑现的类型：直接跳过，一次都不试。
    ///
    /// ⚠️ 这是**种子**，不是全集。列不全各家 App 的私有 UTI，
    /// 所以必须配合负缓存自学习（见 `NegativeTypeCache`）。
    public static let knownUnfulfillable: Set<String> = [
        // 实测阻塞 18.5~23.8 秒后返回 nil 的元凶
        "public.utf16-external-plain-text",
        // 同族，同样不可兑现
        "CorePasteboardFlavorType 0x75743136",
    ]

    /// 未知类型的读取超时。
    ///
    /// 取 1.5s 而非更短：未知类型里可能有**合法但较大**的私有格式，
    /// 阈值太短会把真数据误判成坏类型。反正每个坏类型每会话只付一次这个代价。
    public static let unknownTypeTimeout: TimeInterval = 1.5

    /// 单次快照的总读取预算。超了就停止读剩余未知类型，保住捕获不被拖死。
    public static let totalReadBudget: TimeInterval = 3.0

    public static func classify(_ uti: String) -> Level {
        if trusted.contains(uti) { return .trusted }
        if knownUnfulfillable.contains(uti) { return .skip }
        return .unknown
    }

    public enum Level: Sendable {
        case trusted
        case unknown
        case skip
    }
}

/// 负缓存：本进程内超时过的类型，后续直接跳过。
///
/// 效果：未知的坏类型**每会话最多付一次** `unknownTypeTimeout`，
/// 之后就等同于 `knownUnfulfillable`。硬编码列表因此只是加速器，不是正确性依赖。
public final class NegativeTypeCache: @unchecked Sendable {

    public static let shared = NegativeTypeCache()

    private let lock = NSLock()
    private var badTypes: Set<String> = []

    public init() {}

    public func isBad(_ uti: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return badTypes.contains(uti)
    }

    public func markBad(_ uti: String) {
        lock.lock(); defer { lock.unlock() }
        badTypes.insert(uti)
    }

    /// 可观测：本会话学到了哪些坏类型。用于反馈进硬编码种子列表。
    public var learned: [String] {
        lock.lock(); defer { lock.unlock() }
        return badTypes.sorted()
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        badTypes.removeAll()
    }
}
