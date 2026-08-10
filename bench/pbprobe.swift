import AppKit
import Foundation

func human(_ n: Int) -> String {
    if n >= 1 << 20 { return String(format: "%.2f MB", Double(n) / 1048576) }
    if n >= 1 << 10 { return String(format: "%.1f KB", Double(n) / 1024) }
    return "\(n) B"
}

func dump(_ label: String) {
    let pb = NSPasteboard.general
    print("── \(label)  [changeCount=\(pb.changeCount)]")
    guard let items = pb.pasteboardItems, !items.isEmpty else { print("   (空)"); return }
    var total = 0
    for (i, item) in items.enumerated() {
        for t in item.types {
            let d = item.data(forType: t)
            let n = d?.count ?? 0
            total += n
            var extra = ""
            if n < 200, let d, let s = String(data: d, encoding: .utf8) {
                extra = "  → \(s.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))"
            }
            print(String(format: "   [%d] %-42s %10s%@", i, (t.rawValue as NSString).utf8String!, (human(n) as NSString).utf8String!, extra))
        }
    }
    print("   合计 \(human(total))\n")
}

// ① 当前剪贴板现状
dump("当前剪贴板")

// ② 模拟 Finder 复制文件：Finder 放的是 file-url，不是文件内容
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("probe_fake_video.mp4")
// 造一个 200MB 的假视频
if !FileManager.default.fileExists(atPath: tmp.path) {
    let chunk = Data(count: 1 << 20)
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    let fh = try! FileHandle(forWritingTo: tmp)
    for _ in 0..<200 { fh.write(chunk) }
    try? fh.close()
}
let sz = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
print("造了个测试文件：\(tmp.lastPathComponent) 磁盘占用 \(human(sz ?? 0))")
let pb = NSPasteboard.general
pb.clearContents()
pb.writeObjects([tmp as NSURL])
dump("Finder 式「复制文件」后的剪贴板")

// ③ 模拟复制一张图（截图/浏览器复制图片走这条）
let size = NSSize(width: 3456, height: 2234)   // MacBook Pro 14" 全屏截图分辨率
let img = NSImage(size: size)
img.lockFocus()
NSColor.systemBlue.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
// 加点噪声，避免纯色被极端压缩，更接近真实截图
for _ in 0..<4000 {
    NSColor(calibratedHue: .random(in: 0...1), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: .random(in: 0...size.width), y: .random(in: 0...size.height),
                              width: .random(in: 4...60), height: .random(in: 4...60))).fill()
}
img.unlockFocus()
pb.clearContents()
pb.writeObjects([img])
dump("复制一张 3456×2234 图片后的剪贴板")

// ④ 对比：同一张图 PNG 编码 vs TIFF 原始
if let tiff = img.tiffRepresentation {
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!
    let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    print("── 同一张图的三种编码")
    print("   TIFF(剪贴板原始)  \(human(tiff.count))")
    print("   PNG               \(human(png.count))   = TIFF 的 \(String(format: "%.1f%%", Double(png.count)/Double(tiff.count)*100))")
    print("   JPEG q0.9         \(human(jpg.count))   = TIFF 的 \(String(format: "%.1f%%", Double(jpg.count)/Double(tiff.count)*100))")
}

try? FileManager.default.removeItem(at: tmp)
pb.clearContents()
