import Foundation
import ClipflowCore

/// 面板顶部的分类。按「用户找东西时怎么想」分，不是按内部 ClipKind 一一对应。
///
/// 顺序是刻意的：文本占绝大多数，放最前；图片和文件是有明确视觉特征、
/// 一眼能认出来的两类；剩下的归其他。
enum PanelCategory: String, CaseIterable, Identifiable {
    case all, text, image, file, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:   return "全部"
        case .text:  return "文本"
        case .image: return "图片"
        case .file:  return "文件"
        case .other: return "其他"
        }
    }

    /// nil = 不过滤
    var kinds: Set<ClipKind>? {
        switch self {
        case .all:   return nil
        // 链接、代码、富文本、颜色本质都是文本，用户找的时候不会去想它们的区别
        case .text:  return [.text, .richText, .code, .json, .url, .color]
        case .image: return [.image]
        case .file:  return [.fileRef]
        case .other: return [.other]
        }
    }

    func count(from counts: [ClipKind: Int]) -> Int {
        guard let kinds else { return counts.values.reduce(0, +) }
        return kinds.reduce(0) { $0 + (counts[$1] ?? 0) }
    }
}
