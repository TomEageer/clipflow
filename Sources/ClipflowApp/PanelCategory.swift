import Foundation
import ClipflowCore

/// 面板顶部的分类标签。
///
/// 第一排是**可配置的类型标签**（设置页里勾选），第二排是用户自建分组。
/// 类型标签按「用户找东西时怎么想」分，不是按内部 ClipKind 一一对应 ——
/// 比如「文本」是个合集，把链接/代码/JSON/SQL/富文本都算进去，
/// 因为找东西的时候没人会先想"这条属于哪个 kind"。
///
/// 想单独盯某一类（JSON / SQL / 链接）的人，可以在设置里把那个标签也勾出来。
/// 一条内容同时出现在「文本」和「SQL」两个标签下是**故意的**，不是重复 ——
/// 标签是视角，不是互斥的抽屉。
enum PanelCategory: Hashable, Identifiable {
    case all, text, image, file, other
    case json, sql, shell, url, code, richText, color
    /// 用户自建的分组。取代了原来的「置顶」——
    /// 置顶本质就是只有一个、还不能改名的分组。
    case group(Int64)

    /// 设置页里可勾选的全部类型标签。**「全部」不在其中** —— 它恒定存在、不可取消。
    static let selectable: [PanelCategory] =
        [.text, .image, .file, .other, .json, .sql, .shell, .url, .code, .richText, .color]

    /// 默认显示哪几个。保持和以前一致，升级的人看到的东西不变。
    static let defaultIDs = ["all", "text", "image", "file", "other"]

    var id: String {
        switch self {
        case .all: return "all"
        case .text: return "text"
        case .image: return "image"
        case .file: return "file"
        case .other: return "other"
        case .json: return "json"
        case .sql: return "sql"
        case .shell: return "shell"
        case .url: return "url"
        case .code: return "code"
        case .richText: return "richText"
        case .color: return "color"
        case .group(let g): return "group-\(g)"
        }
    }

    init?(id: String) {
        switch id {
        case "all": self = .all
        case "text": self = .text
        case "image": self = .image
        case "file": self = .file
        case "other": self = .other
        case "json": self = .json
        case "sql": self = .sql
        case "shell": self = .shell
        case "url": self = .url
        case "code": self = .code
        case "richText": self = .richText
        case "color": self = .color
        default: return nil
        }
    }

    var groupID: Int64? {
        if case .group(let g) = self { return g }
        return nil
    }

    func label(groups: [ClipGroup]) -> String {
        switch self {
        case .all:      return L("category.all")
        case .text:     return L("category.text")
        case .image:    return L("category.image")
        case .file:     return L("category.file")
        case .other:    return L("category.other")
        case .json:     return L("category.json")
        case .sql:      return L("category.sql")
        case .shell:    return L("category.shell")
        case .url:      return L("category.url")
        case .code:     return L("category.code")
        case .richText: return L("category.richText")
        case .color:    return L("category.color")
        case .group(let g): return groups.first { $0.id == g }?.name ?? L("category.group")
        }
    }

    /// 设置页里给的一句说明，免得「其他」「富文本」这类标签让人猜
    var hint: String {
        switch self {
        case .all:      return "恒定显示，不可移除"
        case .text:     return "文本类合集：纯文本、富文本、链接、代码、JSON、SQL、颜色"
        case .image:    return "截图与图片"
        case .file:     return "从访达等处复制的文件"
        case .other:    return "识别不出类型的内容"
        case .json:     return "能被解析通过的 JSON"
        case .sql:      return "结构上成立的 SQL（首关键字 + 必配子句 + 括号引号配平）"
        case .shell:    return "shell 命令：curl / git / docker / npm 等"
        case .url:      return "以 http:// 或 https:// 开头的链接"
        case .code:     return "看着像代码的片段"
        case .richText: return "带 HTML / RTF 格式的内容"
        case .color:    return "颜色值"
        case .group:    return ""
        }
    }

    /// nil = 不按类型过滤
    var kinds: Set<ClipKind>? {
        switch self {
        case .all, .group: return nil
        // 链接、代码、JSON、SQL、富文本、颜色本质都是文本，
        // 用户找的时候不会先去想它们的区别
        case .text:     return [.text, .richText, .code, .json, .sql, .shell, .url, .color]
        case .image:    return [.image]
        case .file:     return [.fileRef]
        case .other:    return [.other]
        case .json:     return [.json]
        case .sql:      return [.sql]
        case .shell:    return [.shell]
        case .url:      return [.url]
        case .code:     return [.code]
        case .richText: return [.richText]
        case .color:    return [.color]
        }
    }

    func count(kinds counts: [ClipKind: Int], groups groupCounts: [Int64: Int]) -> Int {
        if case .group(let g) = self { return groupCounts[g] ?? 0 }
        guard let kinds else { return counts.values.reduce(0, +) }
        return kinds.reduce(0) { $0 + (counts[$1] ?? 0) }
    }
}
