import Foundation

/// Core 的本地化取词。
///
/// Core 里确实有面向用户的字符串（类型名、保留期档位…），它们要跟界面一起换语言。
/// 但 Core 有一条硬规则：**禁 import AppKit/SwiftUI**（有测试扫源码守着）——
/// `Foundation` 的本地化不违反这条，所以给 Core 自己配一份 `.lproj` 就行，
/// 不必把这些标签搬到 App 层再映射一遍。
///
/// 语言覆盖由 App 层设置：`CoreLoc.override = "en"`。nil = 跟随系统。
public enum CoreLoc {

    nonisolated(unsafe) public static var override: String? {
        didSet { cached = nil }
    }
    private nonisolated(unsafe) static var cached: Bundle?

    static var bundle: Bundle {
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

    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// 取词短名
func CL(_ key: String) -> String { CoreLoc.text(key) }
