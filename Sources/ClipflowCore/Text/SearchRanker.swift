import Foundation

/// 搜索结果的分层。数值越小越靠前。
///
/// 为什么需要分层：FTS 那边是**字符级**命中（拉丁文按单字符入索引、汉字按 bigram），
/// 所以搜 `user` 会把每一条路径里含 `/Users/` 的都算命中 —— 实测 5893 条库里
/// 命中 756 条，用户真正想要的那条淹没在里面，看起来就是"查不出来"。
///
/// 分层只决定**顺序**，不决定有没有 —— 模糊命中仍然全都在，只是排在后面。
public enum SearchTier: Int, Sendable, Comparable, CaseIterable {
    /// 名字完全相等
    case nameExact = 0
    /// 标题（首个非空行）完全相等
    case titleExact = 1
    /// 名字以查询词开头
    case namePrefix = 2
    /// 标题以查询词开头（「后缀模糊」：abc%）
    case titlePrefix = 3
    /// 出现在内容任意位置（「全模糊」：%abc%）
    case fuzzy = 4

    public static func < (a: SearchTier, b: SearchTier) -> Bool { a.rawValue < b.rawValue }
}

public enum SearchRanker {

    /// 判定一条命中属于哪一层。
    ///
    /// 比较一律先转小写：SQLite 的 LIKE 只对 ASCII 大小写不敏感，
    /// 这里和 SQL 侧口径要一致，否则同一条在两条路径上会被判成两层。
    public static func tier(query: String, name: String?, preview: String) -> SearchTier {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .fuzzy }

        if let name, !name.isEmpty {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if n == q { return .nameExact }
            if n.hasPrefix(q) { return .namePrefix }
        }

        let title = self.title(of: preview).lowercased()
        if title == q { return .titleExact }
        if title.hasPrefix(q) { return .titlePrefix }

        return .fuzzy
    }

    /// 列表行上实际显示的那一行：首个非空行，去掉首尾空白。
    ///
    /// 用首行而不是整段 preview 来判前缀 —— preview 存的是整篇内容
    /// （这个库里最长的一条 1.26 MB），拿整段判"以查询词开头"几乎永远不成立，
    /// 而用户眼里的"开头"就是他在列表里看到的那一行。
    public static func title(of preview: String) -> String {
        for line in preview.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 转义 SQL LIKE 的通配符。用户搜 `100%` 不该变成"以 100 开头的任何东西"。
    /// 配合 `ESCAPE '\'` 使用。
    public static func escapeLike(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
