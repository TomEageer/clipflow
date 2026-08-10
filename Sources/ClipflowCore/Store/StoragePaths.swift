import Foundation

/// 存储布局与权限。
///
/// 目录 700 / 文件 600 —— 实测竞品 Paste 的库是 **644**，同机任意用户可读。
/// 这是零成本可避免的错误，硬编码不做成配置项。
public struct StoragePaths: Sendable {

    public let root: URL
    /// 内容库
    public var contentDB: URL { root.appending(path: "clipflow.sqlite") }
    /// 索引库 —— 与内容库分离（抄 Paste 的 db.sqlite + index.sqlite）。
    /// 收益：索引可整体重建而不动内容、两库可分别调参、加密策略可分离。
    public var indexDB: URL { root.appending(path: "clipflow-index.sqlite") }
    /// 内容寻址存储（CAS），SHA-256 两级分桶
    public var blobs: URL { root.appending(path: "blobs") }
    /// 缩略图，列表滚动不解码原图
    public var thumbs: URL { root.appending(path: "thumbs") }

    public init(root: URL) {
        self.root = root
    }

    public static func defaultLocation() -> StoragePaths {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Clipflow")
        return StoragePaths(root: base)
    }

    /// 建目录并锁权限。目录 700、文件 600。
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, blobs, thumbs] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } else {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
        }
    }

    /// 数据库文件建好后调用，锁 600（含 -wal / -shm 旁文件）
    public func lockDatabasePermissions() {
        let fm = FileManager.default
        for db in [contentDB, indexDB] {
            for suffix in ["", "-wal", "-shm"] {
                let p = db.path + suffix
                if fm.fileExists(atPath: p) {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
                }
            }
        }
    }
}
