import AppKit

/// 来源 App 图标缓存。
///
/// 列表每行都要一个图标，而 `urlForApplication(withBundleIdentifier:)` 要查 Launch Services、
/// `icon(forFile:)` 要读 .icns 并渲染 —— 滚动时每帧对每一行做这两件事会明显卡。
/// bundle id 数量天然很少（就那么几个常用 App），全缓存住，**失败也缓存**，
/// 否则卸载过的 App 会每帧重试一次查找。
@MainActor
enum SourceIcon {

    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleID id: String?) -> NSImage? {
        guard let id, !id.isEmpty else { return nil }
        if let hit = cache[id] { return hit }
        var img: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            // 列表里只用得到小尺寸，让 AppKit 直接给对的那一档，省得每次绘制都缩放
            icon.size = NSSize(width: 16, height: 16)
            img = icon
        }
        cache[id] = img
        return img
    }
}
