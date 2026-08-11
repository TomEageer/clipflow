import Foundation
import GRDB

extension ClipflowStore {

    /// 把库里已有的、其实是 JSON 却被标成文本/富文本/代码的条目改标成 `.json`。
    ///
    /// 为什么需要这么一趟：JSON 判定是**这次**才加进 `TypeClassifier` 的，
    /// 而且必须排在 richText 前面（从网页复制 JSON 时剪贴板上同时有 html/rtf）。
    /// 不回填的话，用户已经攒下的 JSON 条目会一直显示成「格式（富文本）」——
    /// 正是他截图里指出来的那条。
    ///
    /// **代价被两层卡住**：先用 SQL 按"前 3 个字符里有 { 或 ["  粗筛（极强的选择性），
    /// 再对候选逐条真解析。全量解析每条内容是绝对不能做的。
    ///
    /// - Returns: 改标的条数
    @discardableResult
    public func reclassifyJSON(limit: Int = 5000) throws -> Int {
        let candidates: [Int64] = try contentPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM items
                 WHERE kind IN (?, ?, ?)
                   AND (instr(preview, '{') BETWEEN 1 AND 3
                     OR instr(preview, '[') BETWEEN 1 AND 3)
                 ORDER BY usedSeq DESC
                 LIMIT ?
                """,
                arguments: [ClipKind.text.rawValue,
                            ClipKind.richText.rawValue,
                            ClipKind.code.rawValue,
                            limit])
        }
        guard !candidates.isEmpty else { return 0 }

        var hits: [Int64] = []
        for id in candidates {
            guard let reps = try? representations(of: id),
                  let plain = reps.first(where: { $0.uti == "public.utf8-plain-text" }),
                  let d = (try? data(of: plain)) ?? nil,
                  let s = String(data: d, encoding: .utf8),
                  JSONDetector.looksLikeJSON(s) else { continue }
            hits.append(id)
        }
        guard !hits.isEmpty else { return 0 }

        try contentPool.write { db in
            // 一次事务批量改，不要逐条 UPDATE
            let list = hits.map(String.init).joined(separator: ",")
            try db.execute(sql: "UPDATE items SET kind = \(ClipKind.json.rawValue) WHERE id IN (\(list))")
        }
        return hits.count
    }
}
