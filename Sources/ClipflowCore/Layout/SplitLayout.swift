import Foundation

/// 面板左右分栏的宽度计算。
///
/// 放在 Core 而不是视图里，是为了**能被测试盯住**：这段逻辑的价值全在边界上 ——
/// 面板被拉到比两栏下限之和还窄时会怎样、拖到头会不会把某一栏压没。
/// 写在 SwiftUI 的 body 里就只能靠肉眼拖着试。
public enum SplitLayout {

    /// 由比例算出列表宽度，并用两侧下限夹住。
    ///
    /// 存**比例**而不是像素宽度：面板本身可自由拉伸，存死宽度的话
    /// 把窗口拉宽后所有增量都会压给预览，列表永远保持原样。
    ///
    /// - Parameter total: 面板内容区总宽（含分隔条）
    /// - Returns: 列表列宽度。剩下的 `total - splitter - 返回值` 归预览。
    public static func listWidth(total: Double,
                                 ratio: Double,
                                 minList: Double,
                                 minPreview: Double,
                                 splitter: Double) -> Double {
        let usable = max(0, total - splitter)
        // 窄到两边下限都放不下时对半分 —— 让某一栏归零比两边都挤更糟，
        // 归零的那栏用户根本没法再把它拖回来。
        guard usable >= minList + minPreview else { return usable / 2 }
        return min(max(usable * ratio, minList), usable - minPreview)
    }

    /// 拖分隔条：把目标列表宽度换算回比例。夹紧规则与 `listWidth` 一致。
    /// 总宽窄到放不下两栏下限时返回 nil —— 此时是对半分，拖动没有意义。
    public static func ratio(forListWidth width: Double,
                             total: Double,
                             minList: Double,
                             minPreview: Double,
                             splitter: Double) -> Double? {
        let usable = max(1, total - splitter)
        guard usable >= minList + minPreview else { return nil }
        let clamped = min(max(width, minList), usable - minPreview)
        return clamped / usable
    }
}
