import Foundation
import GRDB

extension ClipflowStore {

    /// 就地改写一条条目的文本内容 —— 用户在面板里编辑了原文。
    ///
    /// ⚠️ **旧的 representation 必须全删掉。**
    /// 一条从网页复制的内容同时存着 plain / html / rtf；只改 plain 的话，
    /// 粘出去时接收方多半取富文本那份 —— 用户看到的还是没改之前的内容，
    /// 会以为"编辑没生效"。改过之后富文本就是过期数据，留着只会骗人。
    ///
    /// 同理要重算 `contentHash`：不重算的话，日后再复制**原始那段**内容会命中这条，
    /// 于是"复制 A、粘出来是改过的 B"。
    ///
    /// 类型也重判一次 —— 把一段 JSON 改坏之后它就不该再挂着 JSON 标签。
    public func updateText(_ text: String, itemID: Int64) throws {
        let data = Data(text.utf8)
        let uti = "public.utf8-plain-text"

        // 和入库时同一套指纹算法（uti + data 拼接后取 SHA-256）
        var hasher = Data()
        hasher.append(uti.data(using: .utf8) ?? Data())
        hasher.append(data)
        var newHash = BlobStore.hash(hasher)

        // 撞上别的条目就不动指纹 —— 唯一索引冲突会让整次写入失败，
        // 而"指纹没更新"只是让去重少命中一次，代价小得多
        let clash: Int64? = try contentPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE contentHash = ? AND id <> ?",
                               arguments: [newHash, itemID])
        }
        if clash != nil {
            newHash = try contentPool.read { db in
                try String.fetchOne(db, sql: "SELECT contentHash FROM items WHERE id = ?",
                                    arguments: [itemID])
            } ?? newHash
        }

        var rep: Representation
        if data.count < Compressor.threshold {
            rep = Representation(itemID: itemID, uti: uti, inlineData: data, byteSize: data.count)
        } else if let packed = Compressor.compress(data), packed.count < data.count {
            rep = Representation(itemID: itemID, uti: uti,
                                 blobHash: try blobs.put(packed), codec: .lzfse, byteSize: data.count)
        } else {
            rep = Representation(itemID: itemID, uti: uti,
                                 blobHash: try blobs.put(data), codec: .none, byteSize: data.count)
        }

        var snap = RawSnapshot(representations: [(uti, data, 0)])
        var ctx = IngestContext()
        _ = TypeClassifier().process(&snap, context: &ctx)
        let kind = ctx.kind

        try contentPool.write { db in
            try db.execute(sql: "DELETE FROM representations WHERE itemID = ?", arguments: [itemID])
            try rep.insert(db)
            try db.execute(sql: """
                UPDATE items SET contentHash = ?, preview = ?, byteSize = ?, kind = ? WHERE id = ?
                """, arguments: [newHash, ClipItem.makePreview(text), data.count,
                                   kind.rawValue, itemID])
        }
        try indexDocument(itemID: itemID, fullText: text)
    }
}
