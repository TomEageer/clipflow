import Foundation

/// 剪贴板类型读取策略。
///
/// ## 一次被推翻的错误结论（保留记录，防止重犯）
///
/// 早期实测到「跨进程读 `public.utf16-external-plain-text` 阻塞 18~28 秒后返回 nil」，
/// 一度当成 macOS 的系统缺陷，还据此把该类型列入黑名单跳过。
///
/// **这个结论是错的，根因在测试脚手架**：
///
/// ```
/// 写入进程 run loop 不转（Thread.sleep）：  28536.2ms  nil
/// 写入进程 run loop 在转（真实 App 行为）：      0.2ms  1522B  ✅
/// ```
///
/// 该类型是 **lazy promise**，由拥有者进程**通过 run loop** 兑现。
/// 我的测试写入进程只 `Thread.sleep`、run loop 是死的，承诺永远兑现不了，
/// 于是一路等到系统超时。**真实 App 都在跑 run loop，所以真实场景没有这个问题。**
///
/// 旁证：Maccy（19.3k★）读所有类型、**无任何超时保护**，从无"富文本复制卡顿"的报告。
///
/// 教训：**跨进程行为的测试，对端必须模拟真实进程形态**（跑 run loop），
/// 否则测出来的是脚手架的病，不是被测对象的病。
///
/// ## 现在的策略
///
/// 主路径就是「读所有类型」—— 和 Maccy 一致，保真优先。只做两件事：
/// 1. **过滤已被真实 issue 证明有害的类型**（下方 `harmfulPrefixes` / `harmfulTypes`）
/// 2. **保留一层看门狗兜底** —— 不是为了那个被证伪的系统缺陷，
///    而是为了拥有者进程真的挂了/退出了这类边缘情况（那时 promise 确实无人兑现）
public enum TypePolicy {

    /// 前缀级过滤。抄自 Maccy，来源是真实 issue 而非推测。
    public static let harmfulPrefixes: [String] = [
        // 动态类型：系统给未注册 UTI 生成的临时标识，无稳定语义，存了也没用
        "dyn.",
        // Word 的书签/交叉引用源，读了会把整篇文档带进来（Maccy #613 / #770）
        "com.microsoft.ole.source",
    ]

    /// 精确匹配的有害类型。
    public static let harmfulTypes: Set<String> = [
        // Word 链接源，与 objectlink 同时出现时会引入巨大且无用的 PDF（Maccy #613）
        "com.microsoft.linksource",
        "com.microsoft.objectlink",
    ]

    /// 看门狗超时。
    ///
    /// 只针对**边缘情况**：拥有者进程已退出或挂死，promise 无人兑现。
    /// 取 2s 而非更短 —— 大图的合法读取可能要几百毫秒，阈值太短会把**真数据**误判丢掉。
    /// 正常情况下所有类型都是毫秒级，这条路径根本不会触发。
    public static let readTimeout: TimeInterval = 2.0

    /// 单次快照的总读取预算，防止病态输入把捕获拖死。
    public static let totalReadBudget: TimeInterval = 5.0

    public static func shouldRead(_ uti: String) -> Bool {
        if harmfulTypes.contains(uti) { return false }
        for p in harmfulPrefixes where uti.hasPrefix(p) { return false }
        return true
    }
}

/// 负缓存：本进程内确实超时过的类型，后续跳过。
///
/// ⚠️ 注意它现在的定位变了：**不是主要机制，只是边缘情况的兜底**。
/// 正常 App 的所有类型都能毫秒级读到，这个缓存应该长期为空。
/// `learned` 长期非空说明环境里有 App 行为异常，值得排查而不是默默容忍。
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

    /// 可观测：本会话学到了哪些坏类型。长期非空 = 环境异常，该排查。
    public var learned: [String] {
        lock.lock(); defer { lock.unlock() }
        return badTypes.sorted()
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        badTypes.removeAll()
    }
}
