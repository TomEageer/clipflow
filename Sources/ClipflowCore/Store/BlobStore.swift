import Foundation
import CryptoKit

/// 内容寻址存储（CAS）。SHA-256 命名 + 两级分桶。
///
/// 天然去重：同一张图复制 100 次只占一份磁盘。
/// 实测竞品 Paste 的外置附件里，49 个含 TIFF 的文件吃掉 346 MB（占总量 708 MB 的 49%）。
public struct BlobStore: Sendable {

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// a3f2... → <root>/a3/f2/a3f2...
    public func url(for hash: String) -> URL {
        let a = String(hash.prefix(2))
        let b = String(hash.dropFirst(2).prefix(2))
        return root.appending(path: a).appending(path: b).appending(path: hash)
    }

    public func exists(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    /// 写入并返回 hash。已存在则直接返回，不重复写盘。
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let h = Self.hash(data)
        let dest = url(for: h)
        if FileManager.default.fileExists(atPath: dest.path) { return h }

        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: dest, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return h
    }

    public func get(_ hash: String) throws -> Data {
        try Data(contentsOf: url(for: hash))
    }

    public func delete(_ hash: String) throws {
        let u = url(for: hash)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    /// 统计：文件数与总占用
    public func stats() -> (count: Int, bytes: Int) {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return (0, 0) }
        var count = 0, bytes = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            count += 1
            bytes += v.fileSize ?? 0
        }
        return (count, bytes)
    }
}
