import Foundation
import GRDB

// MARK: - 全文索引：全库唯一的建索引入口

extension ClipflowStore {

    /// 一条内容的完整原文（不是 `preview`）。
    ///
    /// 保真原文存在 `representations` 里，超过 512B 会 LZFSE 压进 CAS。
    /// 想拿全文的地方一律走这里，别再各自去翻 representations ——
    /// 之前面板和索引各写了一份，口径一不致就会出现"看得到却搜不到"。
    public func plainText(of itemID: Int64) -> String? {
        guard let reps = try? representations(of: itemID),
              let plain = reps.first(where: { $0.uti == "public.utf8-plain-text" }),
              let raw = try? data(of: plain),
              let text = String(data: raw, encoding: .utf8)
        else { return nil }
        return text
    }

    /// 重建某条的检索行。**全库只有这一个建索引的地方。**
    ///
    /// 索引文档 = 名字 + 全文 + OCR 文本。三样缺一都会让用户"记得有却搜不到"：
    /// 起了名的要能按名字搜，正文要能全文搜，图片里的字要能搜。
    ///
    /// 为什么必须有这个统一入口：原来有三处各自建索引（入库、改名、OCR 回填），
    /// 三处都拿 `preview` 当全文。等到 `preview` 收敛成摘要，任何一处漏改
    /// 都会**悄悄**把一条内容的可搜范围砍到前 2000 字——不报错、不崩，
    /// 只是用户某天发现搜不到了。这种 bug 不该靠"记得三处都改"来防。
    ///
    /// - Parameter fullText: 已经在手上的全文（入库时有），省一次读盘解压。
    ///   传 nil 就自己去取。
    public func indexDocument(itemID: Int64, fullText: String? = nil) throws {
        guard let item = try item(id: itemID) else { return }

        // 敏感条目不入索引 —— 索引里存的 bigram 拼起来接近原文，等于明文泄漏
        guard item.sensitivity == .normal else {
            try indexPoolWrite { db in
                try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [itemID])
            }
            return
        }

        let body = fullText ?? plainText(of: itemID) ?? item.preview
        // OCR 文本读的也是索引库，得在写事务**之外**先取出来，否则自己锁自己
        let ocr = (try? ocrText(for: itemID)) ?? nil

        let doc = [item.name, body, ocr]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let tok = BigramTokenizer.tokenize(doc)

        try indexPoolWrite { db in
            // contentless FTS 不支持 UPDATE，只能先删后插
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [itemID])
            try db.execute(sql: "INSERT INTO items_fts(rowid, tok) VALUES (?, ?)",
                           arguments: [itemID, tok])
        }
    }
}
