import Foundation
import ClipflowCore

/// 面板顶部的分类。按「用户找东西时怎么想」分，不是按内部 ClipKind 一一对应。
///
/// 顺序是刻意的：文本占绝大多数，放最前；图片和文件是有明确视觉特征、
/// 一眼能认出来的两类；剩下的归其他。自定义分组排在内置分类后面。
enum PanelCategory: Hashable, Identifiable {
    case all, text, image, file, other
    /// 用户自建的分组。取代了原来的「置顶」——
    /// 置顶本质就是只有一个、还不能改名的分组。
    case group(Int64)

    static let builtins: [PanelCategory] = [.all, .text, .image, .file, .other]

    var id: String {
        switch self {
        case .all: return "all"
        case .text: return "text"
        case .image: return "image"
        case .file: return "file"
        case .other: return "other"
        case .group(let g): return "group-\(g)"
        }
    }

    var groupID: Int64? {
        if case .group(let g) = self { return g }
        return nil
    }

    func label(groups: [ClipGroup]) -> String {
        switch self {
        case .all:   return "全部"
        case .text:  return "文本"
        case .image: return "图片"
        case .file:  return "文件"
        case .other: return "其他"
        case .group(let g):
            return groups.first { $0.id == g }?.name ?? "分组"
        }
    }

    /// nil = 不按类型过滤
    var kinds: Set<ClipKind>? {
        switch self {
        case .all, .group: return nil
        // 链接、代码、JSON、富文本、颜色本质都是文本，用户找的时候不会去想它们的区别
        case .text:  return [.text, .richText, .code, .json, .url, .color]
        case .image: return [.image]
        case .file:  return [.fileRef]
        case .other: return [.other]
        }
    }

    func count(kinds counts: [ClipKind: Int], groups groupCounts: [Int64: Int]) -> Int {
        if case .group(let g) = self { return groupCounts[g] ?? 0 }
        guard let kinds else { return counts.values.reduce(0, +) }
        return kinds.reduce(0) { $0 + (counts[$1] ?? 0) }
    }
}
