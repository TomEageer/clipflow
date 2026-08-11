import Foundation

/// 粘贴变换。
///
/// **形态很关键**：这些不是独立的"工具箱"，而是**对选中条目的动作**。
/// 剪贴板管理器本来就站在「复制」与「粘贴」中间，在粘出去的路上做一次转换
/// 是它天然该干的事；单独开一块工具区域会让人疑惑"我是来找刚复制的东西的，
/// 这堆工具是干嘛的"。
///
/// 这是 docs/00 里留的拓展点②。闭源模块实现本协议并 register() 即可挂上。
public protocol Transformer: Sendable {
    var id: String { get }
    var title: String { get }
    /// 归类，UI 上分组显示
    var group: TransformGroup { get }
    /// 只在开发者模式下出现
    var developerOnly: Bool { get }
    /// 内容是否适用。不适用的不显示 —— 列一堆点了没反应的动作最恼人。
    func canApply(to text: String) -> Bool
    func apply(to text: String) throws -> String
}

public enum TransformGroup: String, Sendable, CaseIterable {
    case text = "文本"
    case json = "JSON"
    case encoding = "编码"

    public var order: Int {
        switch self {
        case .text: return 0
        case .json: return 1
        case .encoding: return 2
        }
    }
}

public enum TransformError: Error, LocalizedError {
    case notApplicable(String)

    public var errorDescription: String? {
        switch self {
        case .notApplicable(let m): return m
        }
    }
}

/// 变换注册表 —— D7 定的三个注册点之一。
public final class TransformerRegistry: @unchecked Sendable {

    private var items: [Transformer] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ t: Transformer) {
        lock.lock(); defer { lock.unlock() }
        items.append(t)
    }

    public var all: [Transformer] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// 对给定文本可用的变换，按分组排序。
    public func applicable(to text: String, developerMode: Bool) -> [Transformer] {
        all.filter { t in
            (!t.developerOnly || developerMode) && t.canApply(to: text)
        }
        .sorted { ($0.group.order, $0.title) < ($1.group.order, $1.title) }
    }

    public static func standard() -> TransformerRegistry {
        let r = TransformerRegistry()
        r.register(PlainTextTransformer())
        r.register(TrimBlankLinesTransformer())
        r.register(UppercaseTransformer())
        r.register(LowercaseTransformer())
        r.register(JSONPrettyTransformer())
        r.register(JSONMinifyTransformer())
        r.register(JSONEscapeTransformer())
        r.register(JSONUnescapeTransformer())
        r.register(URLEncodeTransformer())
        r.register(URLDecodeTransformer())
        r.register(Base64EncodeTransformer())
        r.register(Base64DecodeTransformer())
        return r
    }
}

// MARK: - JSON 识别

public enum JSONDetector {

    /// 是不是一段 JSON。**先做廉价的形状判断再真解析** ——
    /// 每条剪贴板内容都要过这一关，不能对着几百 KB 的文本白跑一次解析。
    public static func looksLikeJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 5_000_000 else { return false }
        guard let f = t.first, let l = t.last else { return false }
        guard (f == "{" && l == "}") || (f == "[" && l == "]") else { return false }
        return parse(t) != nil
    }

    public static func parse(_ text: String) -> Any? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// 格式化。`sortedKeys` 关掉 —— 保持原始键序更接近用户看到的东西。
    public static func pretty(_ text: String) -> String? {
        guard let obj = parse(text),
              let d = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    public static func minify(_ text: String) -> String? {
        guard let obj = parse(text),
              let d = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.withoutEscapingSlashes, .fragmentsAllowed]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
}
