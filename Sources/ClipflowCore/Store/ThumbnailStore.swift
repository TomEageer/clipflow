import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// 缩略图生成与缓存。
///
/// 用 **ImageIO** 而非 AppKit —— `ClipflowCore` 必须保持零 UI 依赖（有测试守着）。
/// `CGImageSourceCreateThumbnailAtIndex` 也是更高效的路径：能直接用文件内嵌的缩略图，
/// 不必解码整张原图。列表滚动时**永不解码原图**就是靠这个。
public struct ThumbnailStore: Sendable {

    /// 列表行里的缩略图边长（点）。按 2x 屏取 2 倍像素。
    public static let listSize = 96

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(for contentHash: String, size: Int) -> URL {
        root.appending(path: "\(contentHash)-\(size).png")
    }

    /// 取缩略图，没有就现生成并落盘。
    /// - Returns: PNG 数据；源数据不是图片则返回 nil
    public func thumbnail(for contentHash: String, imageData: @autoclosure () -> Data?,
                          size: Int = ThumbnailStore.listSize) -> Data? {
        let dest = url(for: contentHash, size: size)
        if let cached = try? Data(contentsOf: dest) { return cached }
        guard let data = imageData(), let png = Self.makeThumbnail(from: data, maxPixel: size) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? png.write(to: dest, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return png
    }

    /// 生成缩略图 PNG。
    public static func makeThumbnail(from data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 尊重 EXIF 方向
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 读图片像素尺寸。只读元数据头，**不解码像素**，代价极低。
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}
