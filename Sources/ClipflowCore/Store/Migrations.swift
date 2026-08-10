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
