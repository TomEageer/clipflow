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
    /// internal 而非 private：JSON 回填在 ClipflowStore+ReclassifyJSON.swift 里要用
    let contentPool: DatabasePool
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
    ///
    /// - Parameter fullText: 这一条的全文。`item.preview` 只是裁剪过的摘要，
    ///   建索引要的是全文；入库时它还在调用方手上，传进来省一次读盘解压。
    @discardableResult
    public func insert(item: ClipItem, representations: [Representation],
                       fullText: String? = nil) throws -> Int64 {
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

        // 入库时全文还在手上，直接传进去，省一次读盘解压
        try indexDocument(itemID: newID, fullText: fullText ?? item.preview)
        return newID
    }

    /// 供同模块扩展访问索引库（OCR 队列等）
    func indexPoolWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try indexPool.write(block)
    }
    func indexPoolRead<T>(_ block: (Database) throws -> T) throws -> T {
        try indexPool.read(block)
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
    public func recent(limit: Int = 50, offset: Int = 0,
                       kinds: Set<ClipKind>? = nil,
                       groupID: Int64? = nil) throws -> [ClipItem] {
        try contentPool.read { db in
            // 过滤放进 SQL 而不是取回来再筛 —— 否则"最近 200 条里只有 3 张图"时
            // 用户会以为图片没了
            var where_ = "1 = 1"
            var args: [any DatabaseValueConvertible] = []
            if let kinds, !kinds.isEmpty {
                where_ += " AND kind IN (\(databaseQuestionMarks(count: kinds.count)))"
                args += kinds.map(\.rawValue)
            }
            if let groupID {
                where_ += " AND groupID = ?"
                args.append(groupID)
            }
            args += [limit, offset]
            // 排序不再看 pinned：置顶已经被分组取代，分组有自己的标签页，
            // 再让它们插队到「全部」顶部只会让最近复制的东西找不着。
            return try ClipItem.fetchAll(db, sql: """
                SELECT * FROM items WHERE \(where_)
                ORDER BY usedSeq DESC LIMIT ? OFFSET ?
                """, arguments: StatementArguments(args))
        }
    }

    /// 各类型的条目数，给分类标签显示计数用
    public func countsByKind() throws -> [ClipKind: Int] {
        try contentPool.read { db in
            var out: [ClipKind: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, count(*) AS c FROM items GROUP BY kind") {
                if let k = ClipKind(rawValue: row["kind"] as Int) { out[k] = row["c"] as Int }
            }
            return out
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
    /// **结果分三层排，层内一律按 usedSeq 倒序（越近越靠前）：**
    /// 1. 锚定命中 —— 名字或标题（首个非空行）以查询词开头，完全相等排最前；
    /// 2. 模糊命中 —— 出现在内容任意位置；
    /// 3. 两层内部都按最近使用排。
    ///
    /// 为什么要分层：索引是**字符级**的（拉丁文按单字符、汉字按 bigram），搜 `user`
    /// 会把每条路径里含 `/Users/` 的都算命中 —— 实测 5893 条库里命中 756 条，
    /// 想要的那条淹在里面，用户看到的就是"搜不出来"。分层只改顺序不改召回。
    ///
    /// 为什么锚定命中要**单独走一条 SQL**、不从 FTS 结果里挑：FTS 只能给"最近 N 条
    /// 命中"，一条三个月前的精确匹配会被几百条新的模糊命中挤出候选集，再怎么排也排不出来。
    ///
    /// ⚠️ 模糊层取候选仍用 `fts.rowid DESC`，**不是 `ORDER BY rank`**。
    /// 实测：2 万条命中时 rank 要 46ms（必须给每条打 BM25 分），rowid DESC 只要 0.30ms —— **快 150 倍**。
    /// 剪贴板用户要的本来就是「最近的」不是「最相关的」。
    ///
    /// ⚠️ `kinds` / `groupID` 的过滤必须**进 SQL**，不能取回来再筛 ——
    /// 否则"最近 400 条命中里一条文本都没有"时，在「文本」标签页下就是一片空白
    /// （和 `recent` 那条注释是同一个坑）。
    public func search(_ query: String, limit: Int = 50,
                       kinds: Set<ClipKind>? = nil,
                       groupID: Int64? = nil) throws -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var merged: [Int64: ClipItem] = [:]
        for item in try anchoredMatches(q, limit: limit, kinds: kinds, groupID: groupID) {
            if let id = item.id { merged[id] = item }
        }
        for item in try fuzzyMatches(q, limit: limit, kinds: kinds, groupID: groupID) {
            if let id = item.id { merged[id] = item }
        }
        // 索引表达不了的查询走 LIKE 兜底（词中间的片段、单个汉字）。
        // 只在前两层没填满时才跑 —— 常见查询根本走不到这里。
        var viaFallbackOnly: Set<Int64> = []
        if merged.count < limit {
            for item in try substringMatches(q, limit: limit - merged.count,
                                             kinds: kinds, groupID: groupID) {
                if let id = item.id, merged[id] == nil {
                    merged[id] = item
                    viaFallbackOnly.insert(id)
                }
            }
        }
        guard !merged.isEmpty else { return [] }

        // 分层看**从哪条路径来的**，不能只看文本：只有 LIKE 兜底捞到的，
        // 说明查询词卡在某个词中间，相关性比"正文里有个词以它开头"低一档。
        // 光看 preview 判断不出来 —— 索引命中的位置可能在 2000 字之外。
        let ranked = merged.map { id, item -> (item: ClipItem, tier: SearchTier) in
            let t = SearchRanker.tier(query: q, name: item.name, preview: item.preview)
            return (item, viaFallbackOnly.contains(id) && t == .fuzzy ? .substring : t)
        }
        return ranked
            .sorted {
                $0.tier == $1.tier ? $0.item.usedSeq > $1.item.usedSeq : $0.tier < $1.tier
            }
            .prefix(limit)
            .map(\.item)
    }

    /// 锚定命中：名字或标题以查询词开头（完全相等是它的特例）。
    ///
    /// ⚠️ **必须拆成两条查询，不能写成 `name LIKE ? OR titleKey LIKE ?`。**
    /// 一个 OR 就让 SQLite 放弃两边的索引掉回全表扫（实测查询计划从
    /// `SEARCH USING INDEX idx_items_titleKey` 变成 `SCAN items`）。
    ///
    /// ⚠️ **必须自己挡住敏感条目。** 这条路径直接查 `items` 表、不经过索引，
    /// 而"密钥/密码搜不到"本来是靠**不进索引**实现的 ——
    /// 少了这个条件敏感内容就从这里漏出来了（被既有测试逮到过）。
    ///
    /// `titleKey` 是虚拟生成列（见 v6 迁移），带 `COLLATE NOCASE` 索引，
    /// 所以 `LIKE 'q%'` 走的是索引区间扫描而不是全表扫：
    /// 5 万条实测 8~10ms → 0.023ms。
    private func anchoredMatches(_ query: String, limit: Int,
                                 kinds: Set<ClipKind>?, groupID: Int64?) throws -> [ClipItem] {
        let pattern = SearchRanker.escapeLike(query) + "%"
        var out: [ClipItem] = []
        var seen: Set<Int64> = []
        for column in ["titleKey", "name"] {
            for item in try prefixMatches(column: column, pattern: pattern,
                                          limit: limit, kinds: kinds, groupID: groupID) {
                if let id = item.id, seen.insert(id).inserted { out.append(item) }
            }
        }
        return out
    }

    /// 单列前缀查询。`column` 只取代码里写死的列名，不接受外部输入。
    private func prefixMatches(column: String, pattern: String, limit: Int,
                               kinds: Set<ClipKind>?, groupID: Int64?) throws -> [ClipItem] {
        try contentPool.read { db in
            var where_ = "sensitivity = :normal AND \(column) LIKE :p ESCAPE '\\'"
            var args: [String: (any DatabaseValueConvertible)?] = [
                "p": pattern, "limit": limit, "normal": Sensitivity.normal.rawValue,
            ]
            if let kinds, !kinds.isEmpty {
                let keys = kinds.enumerated().map { ":k\($0.offset)" }
                where_ += " AND kind IN (\(keys.joined(separator: ", ")))"
                for (i, k) in kinds.enumerated() { args["k\(i)"] = k.rawValue }
            }
            if let groupID {
                where_ += " AND groupID = :gid"
                args["gid"] = groupID
            }
            return try ClipItem.fetchAll(db, sql: """
                SELECT * FROM items WHERE \(where_)
                ORDER BY usedSeq DESC LIMIT :limit
                """, arguments: StatementArguments(args))
        }
    }

    /// 子串兜底：`LIKE '%q%'`。
    ///
    /// 为什么需要它：词元索引表达不了两类查询 ——
    /// **词中间的片段**（搜订单号中段 `1401393` 找 `2608191401393454887`）和
    /// **单个汉字**（索引里存的是 bigram，没有单字词元）。
    /// 这是各家的通行做法：SQLite 自带的 trigram 分词器也搞不定少于 3 字的查询，
    /// 相关方案一律拿 LIKE 补这一段。
    ///
    /// 为什么不干脆换 trigram 分词器：它对**两个汉字**的查询就已经无能为力了
    /// （订单、支付、密码全废），而且索引膨胀自然语言约 3×、结构化数据实测到过 18×
    /// —— 剪贴板里全是 JSON/SQL/日志，正踩在最坏情况上。
    ///
    /// ⚠️ 只扫 `preview`（摘要，上限 2000 字），扫不到正文深处 ——
    /// 全文在 CAS 里压着，逐条解压来做 LIKE 是不可接受的。
    ///
    /// ⚠️ **只扫最近 `fallbackScanLimit` 条。** `%q%` 用不上任何索引，就是全表扫：
    /// 5 万条实测 14.7ms，而且**查不到时最慢**（找不到就得看完每一行）。
    /// 不封顶的话它会随库线性劣化，成为搜索延迟的天花板。
    /// 兜底本来就是"尽力而为"的一层，给它一个可预测的上界比让它无限拖慢合理。
    private func substringMatches(_ query: String, limit: Int,
                                  kinds: Set<ClipKind>?, groupID: Int64?) throws -> [ClipItem] {
        let pattern = "%" + SearchRanker.escapeLike(query) + "%"

        return try contentPool.read { db in
            var where_ = """
                sensitivity = :normal
                AND (name LIKE :p ESCAPE '\\' OR preview LIKE :p ESCAPE '\\')
                """
            var args: [String: (any DatabaseValueConvertible)?] = [
                "p": pattern, "limit": limit, "normal": Sensitivity.normal.rawValue,
            ]
            if let kinds, !kinds.isEmpty {
                let keys = kinds.enumerated().map { ":k\($0.offset)" }
                where_ += " AND kind IN (\(keys.joined(separator: ", ")))"
                for (i, k) in kinds.enumerated() { args["k\(i)"] = k.rawValue }
            }
            if let groupID {
                where_ += " AND groupID = :gid"
                args["gid"] = groupID
            }
            args["scan"] = Self.fallbackScanLimit
            return try ClipItem.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT * FROM items ORDER BY usedSeq DESC LIMIT :scan
                ) WHERE \(where_)
                ORDER BY usedSeq DESC LIMIT :limit
                """, arguments: StatementArguments(args))
        }
    }

    /// 子串兜底最多看多少条最近记录。见 `substringMatches` 的说明。
    static let fallbackScanLimit = 20_000

    /// 模糊命中：走 FTS 拿候选，再回内容库按分类取。
    private func fuzzyMatches(_ query: String, limit: Int,
                              kinds: Set<ClipKind>?, groupID: Int64?) throws -> [ClipItem] {
        guard let expr = SearchTokenizer.matchExpression(for: query) else { return [] }

        // 带分类过滤时多要一些候选 —— 过滤发生在候选之后，
        // 候选给得太少会出现"这个标签页下明明有，却一条都不显示"。
        let filtered = (kinds?.isEmpty == false) || groupID != nil
        let candidateLimit = min(2000, max(limit, 200) * (filtered ? 6 : 1))

        let ids: [Int64] = try indexPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM items_fts WHERE items_fts MATCH ?
                ORDER BY rowid DESC LIMIT ?
                """, arguments: [expr, candidateLimit])
        }
        guard !ids.isEmpty else { return [] }

        return try contentPool.read { db in
            var where_ = "id IN (\(databaseQuestionMarks(count: ids.count)))"
            var args: [any DatabaseValueConvertible] = ids
            if let kinds, !kinds.isEmpty {
                where_ += " AND kind IN (\(databaseQuestionMarks(count: kinds.count)))"
                args += kinds.map(\.rawValue)
            }
            if let groupID {
                where_ += " AND groupID = ?"
                args.append(groupID)
            }
            args.append(limit)
            return try ClipItem.fetchAll(db, sql: """
                SELECT * FROM items WHERE \(where_)
                ORDER BY usedSeq DESC LIMIT ?
                """, arguments: StatementArguments(args))
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

    // MARK: 批量删除（供设置页与清理逻辑用）

    /// 按条件删除，同时清索引。返回删除条数。
    func deleteWhere(_ condition: String, _ args: [any DatabaseValueConvertible]) throws -> Int {
        let ids: [Int64] = try contentPool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM items WHERE \(condition)",
                               arguments: StatementArguments(args))
        }
        guard !ids.isEmpty else { return 0 }
        try deleteIDs(ids)
        return ids.count
    }

    /// 保留最近的 limit 条，其余按最久未用删除
    func deleteOldestBeyond(limit: Int) throws -> Int {
        let ids: [Int64] = try contentPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM items WHERE groupID IS NULL
                ORDER BY usedSeq DESC LIMIT -1 OFFSET ?
                """, arguments: [limit])
        }
        guard !ids.isEmpty else { return 0 }
        try deleteIDs(ids)
        return ids.count
    }

    func deleteOldestBatch(count: Int) throws -> Int {
        let ids: [Int64] = try contentPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM items WHERE groupID IS NULL ORDER BY usedSeq ASC LIMIT ?
                """, arguments: [count])
        }
        guard !ids.isEmpty else { return 0 }
        try deleteIDs(ids)
        return ids.count
    }

    public func deleteIDs(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let marks = databaseQuestionMarks(count: ids.count)
        try contentPool.write { db in
            try db.execute(sql: "DELETE FROM items WHERE id IN (\(marks))",
                           arguments: StatementArguments(ids))
        }
        try indexPool.write { db in
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid IN (\(marks))",
                           arguments: StatementArguments(ids))
        }
    }

    /// 清空全部。`keepGrouped` 为真时不动已分组的条目 ——
    /// 用户明确归过类的东西不能被一键清空顺手带走。
    @discardableResult
    public func deleteAll(keepGrouped: Bool = true) throws -> Int {
        try deleteWhere(keepGrouped ? "groupID IS NULL" : "1 = 1", [])
    }

    func allBlobHashes() throws -> [String] {
        try contentPool.read { db in
            try String.fetchAll(db, sql:
                "SELECT DISTINCT blobHash FROM representations WHERE blobHash IS NOT NULL")
        }
    }

    // MARK: 浏览与统计（设置页用）

    public enum SortOrder: String, Sendable, CaseIterable {
        case recentlyUsed, newest, oldest, largest, mostUsed

        public var label: String {
            switch self {
            case .recentlyUsed: return "最近使用"
            case .newest: return "最新创建"
            case .oldest: return "最早创建"
            case .largest: return "占用最大"
            case .mostUsed: return "使用最多"
            }
        }
        var sql: String {
            switch self {
            case .recentlyUsed: return "usedSeq DESC"
            case .newest: return "createdAt DESC"
            case .oldest: return "createdAt ASC"
            case .largest: return "byteSize DESC"
            case .mostUsed: return "useCount DESC, usedSeq DESC"
            }
        }
    }

    public func browse(sort: SortOrder = .recentlyUsed, kind: ClipKind? = nil,
                       source: String? = nil,
                       query: String = "", limit: Int = 500) throws -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var hits = try search(q, limit: limit)
            if let kind { hits = hits.filter { $0.kind == kind } }
            if let source { hits = hits.filter { $0.sourceLabel == source } }
            return hits
        }
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if let kind { conditions.append("kind = ?"); args.append(kind.rawValue) }
        if let source {
            conditions.append("IFNULL(sourceAppName, IFNULL(sourceBundleID, '')) = ?")
            args.append(source)
        }
        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return try contentPool.read { db in
            try ClipItem.fetchAll(db, sql:
                "SELECT * FROM items \(whereSQL) ORDER BY \(sort.sql) LIMIT ?",
                arguments: StatementArguments(args + [limit]))
        }
    }

    /// 按类型统计条数与占用，设置页的存储管理用
    public func breakdownByKind() throws -> [(kind: ClipKind, count: Int, bytes: Int)] {
        try contentPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, count(*) AS c, sum(byteSize) AS b
                FROM items GROUP BY kind ORDER BY b DESC
                """).compactMap { row in
                guard let k = ClipKind(rawValue: row["kind"] as Int) else { return nil }
                return (k, row["c"] as Int, (row["b"] as Int?) ?? 0)
            }
        }
    }

    /// 空闲时维护：合并 FTS 段 + 回收空间。实测 100 万条 optimize 耗时 2.7s，之后检索中位 0.27→0.10ms。
    /// 合并 FTS 段 + 真正回收磁盘空间。
    ///
    /// ⚠️ **必须用 `VACUUM`，不能用 `PRAGMA incremental_vacuum`。**
    /// 后者只在 `auto_vacuum = incremental` 的库上有效，而这两个库都是 `auto_vacuum = 0`
    /// —— 也就是说它一直是**空操作**：实测索引库里躺着 2093 个空闲页没回收，
    /// 而 CLI 和设置页都写着"回收空间"。
    ///
    /// `VACUUM` 不能在事务里跑，所以走 `writeWithoutTransaction`。
    public func optimize() throws {
        try indexPool.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('optimize')")
            try db.execute(sql: "VACUUM")
        }
        try contentPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
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
