import Foundation
import GRDB

// MARK: - 自定义分组

extension ClipflowStore {

    public func groups() throws -> [ClipGroup] {
        try contentPool.read { db in
            try ClipGroup.fetchAll(db, sql: "SELECT * FROM groups ORDER BY sortOrder, id")
        }
    }

    @discardableResult
    public func createGroup(name: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "新分组" : String(trimmed.prefix(24))
        return try contentPool.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortOrder), -1) + 1 FROM groups") ?? 0
            try db.execute(sql: "INSERT INTO groups (name, sortOrder, createdAt) VALUES (?, ?, ?)",
                           arguments: [final, next, Date()])
            return db.lastInsertedRowID
        }
    }

    public func renameGroup(_ id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try contentPool.write { db in
            try db.execute(sql: "UPDATE groups SET name = ? WHERE id = ?",
                           arguments: [String(trimmed.prefix(24)), id])
        }
    }

    /// 按给定顺序重排分组。传进来的 id 列表就是最终顺序。
    ///
    /// 一次事务里全量重写 sortOrder，不做"只挪一个"的增量更新 ——
    /// 增量更新要处理插队、并列、空洞一堆边界，而分组总量只有个位数，
    /// 全量重写既简单又不可能算错。
    public func reorderGroups(_ orderedIDs: [Int64]) throws {
        guard !orderedIDs.isEmpty else { return }
        try contentPool.write { db in
            for (i, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE groups SET sortOrder = ? WHERE id = ?",
                               arguments: [i, id])
            }
        }
    }

    /// 删除分组。**只解绑，不删条目** —— 用户删的是分组这个标签，不是内容本身。
    /// 反过来做的话一次误点会连着内容一起没掉。
    public func deleteGroup(_ id: Int64) throws {
        try contentPool.write { db in
            try db.execute(sql: "UPDATE items SET groupID = NULL WHERE groupID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM groups WHERE id = ?", arguments: [id])
        }
    }

    /// 把条目放进分组；`groupID` 传 nil 表示移出分组
    public func setGroup(_ groupID: Int64?, itemID: Int64) throws {
        try contentPool.write { db in
            try db.execute(sql: "UPDATE items SET groupID = ? WHERE id = ?",
                           arguments: [groupID, itemID])
        }
    }

    /// 各分组的条目数，标签上显示计数用
    public func countsByGroup() throws -> [Int64: Int] {
        try contentPool.read { db in
            var out: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT groupID, count(*) AS c FROM items
                 WHERE groupID IS NOT NULL GROUP BY groupID
                """) {
                if let g = row["groupID"] as Int64? { out[g] = row["c"] as Int }
            }
            return out
        }
    }
}

// MARK: - 命名

extension ClipflowStore {

    /// 给条目起名（传 nil 或空串清除名字）。
    ///
    /// 名字要能被搜到，所以**必须重建这条的 FTS 行** —— 只改 items 表的话
    /// 用户搜自己起的名字什么也搜不出来，会以为命名功能没做。
    public func setName(_ name: String?, itemID: Int64) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = (trimmed?.isEmpty ?? true) ? nil : String(trimmed!.prefix(120))
        try contentPool.write { db in
            try db.execute(sql: "UPDATE items SET name = ? WHERE id = ?", arguments: [final, itemID])
        }
        try indexDocument(itemID: itemID)
    }
}
