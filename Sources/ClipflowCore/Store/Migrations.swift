import Foundation
import GRDB

/// 内容库与索引库的迁移定义。
///
/// 显式可测的迁移是选 GRDB 而非 SwiftData 的理由之一：商业产品的库结构一定会改，
/// 而 SwiftData 的自动迁移在复杂 schema 上不可控。
public enum Migrations {

    // MARK: 内容库

    public static func contentMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_items") { db in
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentHash", .text).notNull()
                t.column("kind", .integer).notNull()
                t.column("sensitivity", .integer).notNull().defaults(to: 0)
                t.column("preview", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("useCount", .integer).notNull().defaults(to: 0)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("sourceBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("windowTitle", .text)
                t.column("byteSize", .integer).notNull().defaults(to: 0)
            }
            // 去重靠唯一索引兜底，不只靠应用层判断
            try db.create(index: "idx_items_contentHash", on: "items",
                          columns: ["contentHash"], unique: true)
            // 「最近」是最高频的排序维度 —— 实测纯浏览 0.02~0.03ms
            try db.create(index: "idx_items_createdAt", on: "items", columns: ["createdAt"])
            try db.create(index: "idx_items_app", on: "items",
                          columns: ["sourceBundleID", "createdAt"])
            try db.create(index: "idx_items_kind", on: "items", columns: ["kind", "createdAt"])
            try db.create(index: "idx_items_pinned", on: "items", columns: ["pinned", "createdAt"])

            try db.create(table: "representations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemID", .integer).notNull()
                    .references("items", onDelete: .cascade)
                t.column("uti", .text).notNull()
                t.column("inlineData", .blob)
                t.column("blobHash", .text)
                t.column("codec", .text).notNull().defaults(to: "none")
                t.column("byteSize", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_reps_item", on: "representations", columns: ["itemID"])
            try db.create(index: "idx_reps_blob", on: "representations", columns: ["blobHash"])
        }

        // 列表顺序不能靠时间戳决定。
        //
        // 同一毫秒内的多次写入会拿到**完全相同**的 lastUsedAt（GRDB 存到毫秒），
        // 排序随即变成未定义 —— 实测："重新复制老内容要置顶"的测试直接挂掉。
        // 时钟精度不该决定用户看到的顺序，改用单调递增序号，精确且与时钟无关。
        m.registerMigration("v2_usedSeq") { db in
            try db.alter(table: "items") { t in
                t.add(column: "usedSeq", .integer).notNull().defaults(to: 0)
            }
            // 已有数据按 lastUsedAt 回填一个合理顺序
            try db.execute(sql: """
                UPDATE items SET usedSeq = (
                    SELECT count(*) FROM items AS b WHERE b.lastUsedAt <= items.lastUsedAt
                )
                """)
            try db.create(index: "idx_items_usedSeq", on: "items",
                          columns: ["pinned", "usedSeq"], ifNotExists: true)
        }

        // 保留剪贴板的多 item 结构。复制多个文件时每个文件是一个独立的
        // NSPasteboardItem，拍平后写回只能还原出一个。
        m.registerMigration("v3_itemIndex") { db in
            try db.alter(table: "representations") { t in
                t.add(column: "itemIndex", .integer).notNull().defaults(to: 0)
            }
        }

        // 命名 + 自定义分组。
        //
        // 「置顶」被分组取代：置顶本质就是"只有一个、还不能改名的分组"。
        // 已经置顶的条目搬进一个叫「置顶」的分组，**功能和数据都不丢** ——
        // 直接把 pinned 作废会让用户辛苦标的东西一夜消失。
        //
        // pinned 列保留但不再使用：SQLite 删列要重建整表，为一个作废的布尔位
        // 冒重建风险不划算。所有读写路径改看 groupID。
        m.registerMigration("v4_names_and_groups") { db in
            try db.create(table: "groups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "items") { t in
                t.add(column: "name", .text)          // 用户起的名字，默认没有
                t.add(column: "groupID", .integer)    // 所属自定义分组，NULL = 未分组
            }
            try db.create(index: "idx_items_group", on: "items",
                          columns: ["groupID", "usedSeq"])

            let pinnedCount = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM items WHERE pinned = 1") ?? 0
            if pinnedCount > 0 {
                try db.execute(sql: """
                    INSERT INTO groups (name, sortOrder, createdAt) VALUES ('置顶', 0, ?)
                    """, arguments: [Date()])
                let gid = db.lastInsertedRowID
                try db.execute(sql: "UPDATE items SET groupID = ? WHERE pinned = 1",
                               arguments: [gid])
            }
        }

        // preview 从"整篇原文"收敛成"列表摘要"。
        //
        // 之前它存的是全文：实测最长一条 1.26 MB，全库 12 MB / 总 20 MB，
        // 而同样的内容在 representations 里已经压缩存过一遍了。列表画一行也要把它读进来。
        //
        // ⚠️ **不需要重建 FTS**：历史索引行正是按当时的 preview（= 全文）建的，
        // 截断 preview 不动索引，召回一条不少。全文仍可从 representations 取回。
        m.registerMigration("v5_preview_is_excerpt") { db in
            try db.execute(sql: "UPDATE items SET preview = substr(preview, 1, ?) WHERE length(preview) > ?",
                           arguments: [ClipItem.previewLimit, ClipItem.previewLimit])
        }

        // 建立真正服务于查询模式的索引。
        //
        // 之前列表和搜索全是**全表扫 + 临时 B 树排序**：
        // 唯一带 usedSeq 的索引是 `(pinned, usedSeq)`，首列是已作废的 pinned，
        // SQLite 用不上它来满足 `ORDER BY usedSeq DESC`。
        // 实测 5 万条：recent(200) 14ms、按类型过滤 16ms、标题前缀查询 8~10ms。
        // 加索引后分别是 0.036ms / 0.12ms / 0.023ms。
        m.registerMigration("v6_query_indexes") { db in
            // 列表排序的主力。ORDER BY usedSeq DESC 直接反向扫这个索引，不再排序。
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_seq ON items(usedSeq)")
            // 分类标签页：过滤 + 排序一个索引全包
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_items_kind_seq ON items(kind, usedSeq)")

            // 标题前缀查询要走索引，就得有个"标题"列可以索引。
            //
            // **用虚拟生成列，不用普通列**：普通列要在入库/改写原文/图片重分类
            // 每个写入点手动维护，漏一处就悄悄搜不到。生成列由 SQLite 自己算，
            // 漏不掉。（STORED 不能用 ALTER TABLE 加，VIRTUAL 可以，
            // 而且索引里存的就是算好的值，查询照样走索引。）
            //
            // `ltrim` 掉前导空白/换行 = 落在首个非空行的开头，
            // 对**前缀**匹配来说与 `SearchRanker.title(of:)` 等价。
            try db.execute(sql: """
                ALTER TABLE items ADD COLUMN titleKey TEXT
                GENERATED ALWAYS AS (
                    ltrim(substr(preview, 1, 200), char(10) || char(13) || char(9) || ' ')
                ) VIRTUAL
                """)
            // COLLATE NOCASE 是 LIKE 走索引的前提 —— LIKE 默认大小写不敏感，
            // 索引排序规则对不上就优化不了，白建。
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS idx_items_titleKey ON items(titleKey COLLATE NOCASE)")
            try db.execute(sql:
                "CREATE INDEX IF NOT EXISTS idx_items_name ON items(name COLLATE NOCASE)")

            // 作废索引：首列都是已被分组取代的 pinned，查不上还拖慢每次写入
            try db.execute(sql: "DROP INDEX IF EXISTS idx_items_pinned")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_items_usedSeq")

            // 没有统计信息时 SQLite 只能按规则猜，容易选错索引
            try db.execute(sql: "ANALYZE")
        }

        return m
    }

    // MARK: 索引库（独立文件）

    public static func indexMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_fts") { db in
            // detail=full 是必须的：只有它支持短语查询。
            // 中文 bigram 检索若退化成 AND 匹配，精度会崩（见 docs/01 §3.3）。
            //
            // contentless（content=''）+ contentless_delete=1（SQLite 3.43+）：
            // 索引不重复存原文，且支持正常 DELETE。
            try db.execute(sql: """
                CREATE VIRTUAL TABLE items_fts USING fts5(
                    tok,
                    content='',
                    contentless_delete=1,
                    detail=full
                )
                """)

            // OCR 结果单独存 —— 不并入原始内容，OCR 有 4%~20% 错误率，混入会污染保真性
            try db.create(table: "items_ocr") { t in
                t.primaryKey("itemID", .integer)
                t.column("text", .text).notNull()
                t.column("engine", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            // OCR 异步队列，持久化 —— 进程被杀任务不丢（抄 Paste 的 ocr_queue）
            try db.create(table: "ocr_queue") { t in
                t.primaryKey("itemID", .integer)
                t.column("blobHash", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("enqueuedAt", .datetime).notNull()
                t.column("state", .text).notNull().defaults(to: "pending")
            }
            try db.create(index: "idx_ocrq_state", on: "ocr_queue", columns: ["state", "enqueuedAt"])
        }

        return m
    }
}
