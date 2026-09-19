import Foundation
import GRDB

/// OCR 队列与结果。
///
/// 队列**持久化在索引库**里：OCR 是秒级任务，进程被杀不能丢。
/// 结果单独存 `items_ocr`，**不并入原始内容** —— OCR 有 4%~20% 错误率，
/// 混进去会污染保真度，而保真正是本项目的卖点。
extension ClipflowStore {

    public struct OCRJob: Sendable {
        public let itemID: Int64
        public let blobHash: String
        public let attempts: Int
    }

    public struct OCRResult: Sendable {
        public let text: String
        public let engine: String
        public let confidence: Double

        public init(text: String, engine: String, confidence: Double) {
            self.text = text
            self.engine = engine
            self.confidence = confidence
        }
    }

    /// 图片入库后排队等 OCR。重复入队无副作用（主键冲突即忽略）。
    public func enqueueOCR(itemID: Int64, blobHash: String) throws {
        try indexPoolWrite { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO ocr_queue(itemID, blobHash, attempts, enqueuedAt, state)
                VALUES (?, ?, 0, ?, 'pending')
                """, arguments: [itemID, blobHash, Date()])
        }
    }

    public func pendingOCRJobs(limit: Int = 20) throws -> [OCRJob] {
        try indexPoolRead { db in
            try Row.fetchAll(db, sql: """
                SELECT itemID, blobHash, attempts FROM ocr_queue
                WHERE state = 'pending' ORDER BY enqueuedAt ASC LIMIT ?
                """, arguments: [limit]).map {
                OCRJob(itemID: $0["itemID"], blobHash: $0["blobHash"], attempts: $0["attempts"])
            }
        }
    }

    public func pendingOCRCount() throws -> Int {
        try indexPoolRead { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM ocr_queue WHERE state = 'pending'") ?? 0
        }
    }

    /// 记录 OCR 结果并把文字并入搜索索引。
    ///
    /// - Parameter sensitive: 命中敏感规则时只存结果不进索引 ——
    ///   截图里的密码经 OCR 会变成明文可搜索字符串，那会绕过整个敏感内容策略。
    public func completeOCR(itemID: Int64, result: OCRResult, sensitive: Bool) throws {
        try indexPoolWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO items_ocr(itemID, text, engine, confidence, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [itemID, result.text, result.engine, result.confidence, Date()])
            try db.execute(sql: "DELETE FROM ocr_queue WHERE itemID = ?", arguments: [itemID])
        }
        guard !sensitive, !result.text.isEmpty else { return }
        // OCR 文本由 indexDocument 自己从 items_ocr 取，这里只要触发重建
        try indexDocument(itemID: itemID)
    }

    /// 无文字或识别失败：记录状态，避免反复重试同一张图。
    public func failOCR(itemID: Int64, reason: String, giveUp: Bool) throws {
        try indexPoolWrite { db in
            if giveUp {
                try db.execute(sql: "UPDATE ocr_queue SET state = ? WHERE itemID = ?",
                               arguments: [reason, itemID])
            } else {
                try db.execute(sql: "UPDATE ocr_queue SET attempts = attempts + 1 WHERE itemID = ?",
                               arguments: [itemID])
            }
        }
    }

    public func ocrText(for itemID: Int64) throws -> String? {
        try indexPoolRead { db in
            try String.fetchOne(db, sql: "SELECT text FROM items_ocr WHERE itemID = ?",
                                arguments: [itemID])
        }
    }

    public func ocrStats() throws -> (done: Int, pending: Int, skipped: Int) {
        try indexPoolRead { db in
            let done = try Int.fetchOne(db, sql: "SELECT count(*) FROM items_ocr") ?? 0
            let pending = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM ocr_queue WHERE state = 'pending'") ?? 0
            let skipped = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM ocr_queue WHERE state != 'pending'") ?? 0
            return (done, pending, skipped)
        }
    }
}
