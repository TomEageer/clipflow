import SwiftUI

/// 界面缩放。
///
/// 不用系统的 Dynamic Type —— macOS 上对普通 App 支持有限，且我们要的是
/// "整块面板等比放大"，不是只放大正文。所有字号与间距都从这里取，乘同一个系数。
struct Theme {
    var scale: Double = 1.0

    func size(_ base: CGFloat) -> CGFloat { base * scale }
    func font(_ base: CGFloat, weight: Font.Weight = .regular,
              design: Font.Design = .default) -> Font {
        .system(size: base * scale, weight: weight, design: design)
    }

    /// 行高、缩略图这类需要跟着字号走的尺寸
    var rowThumbHeight: CGFloat { 26 * scale }
    var rowThumbWidth: CGFloat { 34 * scale }
    var iconColumn: CGFloat { 34 * scale }
    var listWidth: CGFloat { 380 * scale }
    var previewWidth: CGFloat { 320 * scale }

    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5]
    static func label(_ s: Double) -> String {
        switch s {
        case 0.85: return "紧凑"
        case 1.0:  return "标准"
        case 1.15: return "偏大"
        case 1.3:  return "大"
        default:   return "特大"
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
