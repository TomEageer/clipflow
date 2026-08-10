import Foundation

/// 本地化取词。
///
/// 走标准 `.lproj` + `Bundle.module`，不自己造轮子 —— 系统会按用户的语言偏好
/// 自动匹配，包括"简中不可用时退英文"这类回退逻辑。
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Bundle.module.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}
