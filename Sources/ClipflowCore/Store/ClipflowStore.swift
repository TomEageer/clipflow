import Foundation
import GRDB

/// 存储层门面：内容库 + 索引库 + CAS。
///
/// 并发模型：GRDB `DatabasePool`（WAL）—— 单写者串行、多读者并发。
/// **UI 线程永不碰 DB**（这正是弃 SwiftData 的核心理由：它的 ModelContext 绑 MainActor）。
public final class ClipflowStore: Sendable {

    public let paths: StoragePaths
    public let blobs: BlobStore
    public let thumbnails: ThumbnailStore
    private let contentPool: DatabasePool
    private let indexPool: DatabasePool

    public init(paths: StoragePaths) throws {
        self.paths = paths
        try paths.prepare()
        self.blobs = BlobStore(root: paths.blobs)
        self.thumbnails = ThumbnailStore(root: paths.thumbs)

        var config = Configuration()
        // ⚠️ 只放**每连接**的 pragma。DatabasePool 的 reader 连接是只读的，
        //    在这里执行 auto_vacuum 这类写 pragma 会直接抛 "readonly database"。
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        self.contentPool = try DatabasePool(path: paths.contentDB.path, configuration: config)
        self.indexPool = try DatabasePool(path: paths.indexDB.path, configuration: config)

        // auto_vacuum 是**库级**设置，且只在库还没有表时设置才生效 —— 必须在迁移之前、且走写连接。
        // 不设它的话，删条目后 SQLite 不还盘，磁盘只涨不降。
        for pool in [contentPool, indexPool] {
            try pool.write { db in
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
        }

        try Migrations.contentMigrator().migrate(contentPool)
        try Migrations.indexMigrator().migrate(indexPool)

        paths.lockDatabasePermissions()
    }

    // MARK: 写入

    /// 写入一个条目及其全部 representation。
    /// contentHash 命中已有条目则只更新 lastUsedAt / useCount，不新建行。
    @discardableResult
    public func insert(item: ClipItem, representations: [Representation]) throws -> Int64 {
        let existingID: Int64? = try contentPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE contentHash = ?",
                               arguments: [item.contentHash])
        }

        if let id = existingID {
            try contentPool.write { db in
                try db.execute(sql: """
                    UPDATE items
                    SET lastUsedAt = ?, useCount = useCount + 1,
                        usedSeq = (SELECT IFNULL(MAX(usedSeq), 0) + 1 FROM items)
                    WHERE id = ?
                    """, arguments: [Date(), id])
            }
            return id
        }

        var stored = item
        let newID: Int64 = try contentPool.write { db in
            stored.usedSeq = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(usedSeq), 0) + 1 FROM items")) ?? 1
            try stored.insert(db)
            let id = stored.id!
            for var rep in representations {
                rep.itemID = id
                try rep.insert(db)
            }
            return id
        }

        // 敏感条目不入索引 —— 索引里存的 bigram 分词拼起来接近原文，等于明文泄漏
        if item.sensitivity == .normal {
            try indexFTS(itemID: newID, text: item.preview)
        }
        return newID
    }

    public func indexFTS(itemID: Int64, text: String) throws {
        let tok = BigramTokenizer.tokenize(text)
        try indexPool.write { db in
            try db.execute(sql: "INSERT INTO items_fts(rowid, tok) VALUES (?, ?)",
                           arguments: [itemID, tok])
        }
    }

    // MARK: 读取

    /// 最近条目。
    ///
    /// 按 **usedSeq**（单调递增序号）排序，不是 createdAt 也不是 lastUsedAt：
    /// - 不用 createdAt：重新复制老内容时去重命中已有条目，按创建时间排它会继续沉在底部，
    ///   用户明明刚复制过却要翻半天。所有剪贴板工具都是置顶的。
    /// - 不用 lastUsedAt：同一毫秒内的多次写入时间戳完全相同，排序变成未定义（实测挂过测试）。
    ///   时钟精度不该决定用户看到的顺序。
    ///
    /// **恒定按时间排，绝不 ORDER BY rank。**
    public func recent(limit: Int = 50, offset: Int = 0) throws -> [ClipItem] {
        try contentPool.read { db in
            try ClipItem.fetchAll(db, sql: """
                SELECT * FROM items ORDER BY pinned DESC, usedSeq DESC LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
        }
    }

    /// 置顶 / 取消置顶
    public func setPinned(_ pinned: Bool, itemID: Int64) throws {
        try contentPool.write { db in
            try db.execute(sql: "UPDATE items SET pinned = ? WHERE id = ?",
                           arguments: [pinned, itemID])
        }
    }

    /// 标记为刚使用过（粘贴后调用），让它冒到列表顶部
    public func touch(itemID: Int64) throws {
        try contentPool.write { db in
            try db.execute(sql: """
                UPDATE items
                SET lastUsedAt = ?, useCount = useCount + 1,
                    usedSeq = (SELECT IFNULL(MAX(usedSeq), 0) + 1 FROM items)
                WHERE id = ?
                """, arguments: [Date(), itemID])
        }
    }

    /// 全文检索。
    ///
    /// ⚠️ 排序用 `fts.rowid DESC` 而不是 `ORDER BY rank`。
    /// 实测：2 万条命中时 rank 要 46ms（必须给每条打 BM25 分），rowid DESC 只要 0.30ms —— **快 150 倍**。
    /// 且剪贴板用户要的本来就是「最近的」不是「最相关的」，**又快又更对**。
    public func search(_ query: String, limit: Int = 50) throws -> [ClipItem] {
        guard let expr = BigramTokenizer.matchExpression(for: query) else { return [] }

        let ids: [Int64] = try indexPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM items_fts WHERE items_fts MATCH ?
                ORDER BY rowid DESC LIMIT ?
                """, arguments: [expr, limit])
        }
        guard !ids.isEmpty else { return [] }

        return try contentPool.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let items = try ClipItem.fetchAll(db, sql: """
                SELECT * FROM items WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            // 保持索引给出的顺序（最近优先）
            let byID = Dictionary(uniqueKeysWithValues: items.compactMap { i in i.id.map { ($0, i) } })
            return ids.compactMap { byID[$0] }
        }
    }

    /// 取某条的缩略图（图片条目才有）。没有就现生成并落盘。
    /// 列表滚动只读这个，**永不解码原图**。
    public func thumbnail(for item: ClipItem, size: Int = ThumbnailStore.listSize) -> Data? {
        guard item.kind == .image, let id = item.id else { return nil }
        return thumbnails.thumbnail(for: item.contentHash, imageData: {
            guard let reps = try? representations(of: id) else { return nil }
            // 优先用体积最小的图片表示做缩略图源，省解码开销
            let imageReps = reps
                .filter { $0.uti.contains("png") || $0.uti.contains("tiff")
                       || $0.uti.contains("jpeg") || $0.uti.contains("heic") }
                .sorted { $0.byteSize < $1.byteSize }
            for r in imageReps {
                if let d = try? data(of: r), d != nil { return d }
            }
            return nil
        }(), size: size)
    }

    public func item(id: Int64) throws -> ClipItem? {
        try contentPool.read { db in
            try ClipItem.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id])
        }
    }

    public func representations(of itemID: Int64) throws -> [Representation] {
        try contentPool.read { db in
            try Representation.fetchAll(db, sql:
                "SELECT * FROM representations WHERE itemID = ? ORDER BY id", arguments: [itemID])
        }
    }

    /// 取回某个 representation 的原始数据（内联直取 / 外置读 CAS 并解压）
    public func data(of rep: Representation) throws -> Data? {
        if let inline = rep.inlineData { return inline }
        guard let hash = rep.blobHash else { return nil }
        let raw = try blobs.get(hash)
        switch rep.codec {
        case .none:  return raw
        case .lzfse: return Compressor.decompress(raw, originalSize: rep.byteSize)
        }
    }

    // MARK: 维护与统计

    public func count() throws -> Int {
        try contentPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM items") ?? 0
        }
    }

    public func delete(itemID: Int64) throws {
        try contentPool.write { db in
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [itemID])
        }
        try indexPool.write { db in
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [itemID])
        }
    }

    /// 空闲时维护：合并 FTS 段 + 回收空间。实测 100 万条 optimize 耗时 2.7s，之后检索中位 0.27→0.10ms。
    public func optimize() throws {
        try indexPool.write { db in
            try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('optimize')")
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
        try contentPool.write { db in
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    public struct Stats: Sendable {
        public let items: Int
        public let contentDBBytes: Int
        public let indexDBBytes: Int
        public let blobCount: Int
        public let blobBytes: Int
        public var totalBytes: Int { contentDBBytes + indexDBBytes + blobBytes }
    }

    public func stats() throws -> Stats {
        func size(_ url: URL) -> Int {
            var total = 0
            for s in ["", "-wal", "-shm"] {
                let p = url.path + s
                if let a = try? FileManager.default.attributesOfItem(atPath: p),
                   let n = a[.size] as? Int { total += n }
            }
            return total
        }
        let b = blobs.stats()
        return Stats(items: try count(),
                     contentDBBytes: size(paths.contentDB),
                     indexDBBytes: size(paths.indexDB),
                     blobCount: b.count,
                     blobBytes: b.bytes)
    }
}

@inline(__always)
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
