import Foundation
import ClipflowCore

/// 本地化取词。
///
/// 走标准 `.lproj` + `Bundle.module`，不自己造轮子 —— 系统会按用户的语言偏好
/// 自动匹配，包括"简中不可用时退英文"这类回退逻辑。
///
/// 在此之上多一层**手动覆盖**：设置里可以强制中文或英文。
/// 默认是「跟随系统」，也就是不覆盖、完全交给系统匹配 ——
/// 这才是绝大多数人要的（换了系统语言，App 跟着变，不用再进设置改一次）。
enum Loc {

    /// nil = 跟随系统。非 nil 时强制用这个语言的 lproj。
    ///
    /// 全程只在主线程读写（App 启动时设一次、设置页改一次），
    /// 所以标 `nonisolated(unsafe)` 而不是套 actor —— 取词是热路径，
    /// 每个 body 求值都要走，不该为它引入跨 actor 跳转。
    nonisolated(unsafe) static var override: String? {
        didSet {
            cached = nil
            // Core 也有面向用户的字符串（类型名、变换名），要跟着一起换
            CoreLoc.override = override
        }
    }

    private nonisolated(unsafe) static var cached: Bundle?

    private static var bundle: Bundle {
        if let cached { return cached }
        guard let code = override,
              let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else {
            cached = Bundle.module
            return Bundle.module
        }
        cached = b
        return b
    }

    static func text(_ key: String, _ args: CVarArg...) -> String {
        let fmt = bundle.localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? fmt : String(format: fmt, arguments: args)
    }
}

/// 取词短名。`L("panel.search")`
func L(_ key: String, _ args: CVarArg...) -> String {
    Loc.text(key, args)
}

/// 界面语言选项。
enum AppLanguage: String, CaseIterable, Identifiable {
    /// 跟随系统 —— 默认，也是绝大多数人要的
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// 语言名用**该语言自己的写法**（英文写 English 而不是"英语"）——
    /// 一个只会英文的用户在中文界面里，得能认出哪一项是自己的语言。
    var label: String {
        switch self {
        case .system: return L("lang.system")
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }

    /// 传给 `Loc.override`：跟随系统时是 nil
    var overrideCode: String? { self == .system ? nil : rawValue }
}
