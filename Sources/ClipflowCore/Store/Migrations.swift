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
