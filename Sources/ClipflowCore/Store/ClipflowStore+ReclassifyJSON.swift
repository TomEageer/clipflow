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
    /// 把已经标成「文件」、但其实带着图片数据的条目改回「图片」。
    ///
    /// 不少 App（微信、飞书…）复制图片时同时给 file-url 和图片数据，
    /// 而旧版本的分类器先判 file-url —— 这些条目就被标成了文件、预览是一长串路径。
    /// 图片数据一直好好存着，只是标错了，所以能就地改回来，顺带把预览换成尺寸。
    ///
    /// - Returns: 改标的条数
    @discardableResult
    public func reclassifyImages(limit: Int = 5000) throws -> Int {
        let candidates: [Int64] = try contentPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM items WHERE kind = ? ORDER BY usedSeq DESC LIMIT ?
                """, arguments: [ClipKind.fileRef.rawValue, limit])
        }
        var fixed: [(id: Int64, preview: String)] = []
        for id in candidates {
            guard let reps = try? representations(of: id),
                  let img = reps.first(where: { TypeClassifier.isImageUTI($0.uti) }) else { continue }
            let f = ByteCountFormatter()
            let size = f.string(fromByteCount: Int64(img.byteSize))
            // 尺寸要读真实数据，但只解析元数据头、不解码像素
            var preview = "图片 · \(size)"
            if let d = (try? data(of: img)) ?? nil,
               let px = ThumbnailStore.pixelSize(of: d) {
                preview = "图片 \(px.width)×\(px.height) · \(size)"
            }
            fixed.append((id, preview))
        }
        guard !fixed.isEmpty else { return 0 }
        try contentPool.write { db in
            for f in fixed {
                try db.execute(sql: "UPDATE items SET kind = ?, preview = ? WHERE id = ?",
                               arguments: [ClipKind.image.rawValue, f.preview, f.id])
            }
        }
        return fixed.count
    }

    /// - Returns: 改标的条数（JSON + SQL 合计）
    @discardableResult
    public func reclassifyJSON(limit: Int = 5000) throws -> Int {
        // 粗筛：只看 preview 就能排掉绝大多数。**绝不能全量读 blob 再判**。
        let candidates: [(id: Int64, preview: String)] = try contentPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, preview FROM items
                 WHERE kind IN (?, ?, ?)
                 ORDER BY usedSeq DESC
                 LIMIT ?
                """,
                arguments: [ClipKind.text.rawValue,
                            ClipKind.richText.rawValue,
                            ClipKind.code.rawValue,
                            limit])
                .map { (($0["id"] as Int64), ($0["preview"] as String)) }
        }
        guard !candidates.isEmpty else { return 0 }

        var jsonHits: [Int64] = []
        var sqlHits: [Int64] = []
        var shellHits: [Int64] = []
        for c in candidates {
            // 粗筛只看 preview 的开头，代价可忽略；真判定才去读全文
            // （preview 是截断的，括号/引号配平判不准）
            let head = SQLDetector.stripLeadingComments(c.preview).prefix(1)
            let mightBeJSON = head == "{" || head == "["
            let mightBeText = !c.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard mightBeJSON || mightBeText else { continue }

            guard let reps = try? representations(of: c.id),
                  let plain = reps.first(where: { $0.uti == "public.utf8-plain-text" }),
                  let d = (try? data(of: plain)) ?? nil,
                  let s = String(data: d, encoding: .utf8) else { continue }
            if mightBeJSON, JSONDetector.looksLikeJSON(s) { jsonHits.append(c.id) }
            else if SQLDetector.looksLikeSQL(s) { sqlHits.append(c.id) }
            else if ShellDetector.looksLikeShell(s) { shellHits.append(c.id) }
        }
        guard !jsonHits.isEmpty || !sqlHits.isEmpty || !shellHits.isEmpty else { return 0 }

        try contentPool.write { db in
            // 一次事务批量改，不要逐条 UPDATE
            if !jsonHits.isEmpty {
                let list = jsonHits.map(String.init).joined(separator: ",")
                try db.execute(sql: "UPDATE items SET kind = \(ClipKind.json.rawValue) WHERE id IN (\(list))")
            }
            if !sqlHits.isEmpty {
                let list = sqlHits.map(String.init).joined(separator: ",")
                try db.execute(sql: "UPDATE items SET kind = \(ClipKind.sql.rawValue) WHERE id IN (\(list))")
            }
            if !shellHits.isEmpty {
                let list = shellHits.map(String.init).joined(separator: ",")
                try db.execute(sql: "UPDATE items SET kind = \(ClipKind.shell.rawValue) WHERE id IN (\(list))")
            }
        }
        return jsonHits.count + sqlHits.count + shellHits.count
    }
}
