import AppKit
import Foundation
// 四种不同的写入方式，看哪种会广告出无法兑现的 utf16-external-plain-text
let pb = NSPasteboard.general
let mode = CommandLine.arguments[1]
let body = String(repeating: "分布式锁必须用 SETNX 原子操作。", count: 40)

switch mode {
case "item-setString":          // 我原来的测试写法
    pb.clearContents()
    let i = NSPasteboardItem()
    i.setString(body, forType: .string)
    i.setString("<html><b>\(body)</b></html>", forType: .html)
    i.setData(Data("{\\rtf1 \(body)}".utf8), forType: .rtf)
    pb.writeObjects([i])
case "attributedString":        // TextEdit / 浏览器复制富文本的典型写法
    pb.clearContents()
    let a = NSAttributedString(string: body, attributes: [
        .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.systemRed])
    pb.writeObjects([a])
case "declareTypes":            // 老式 API
    pb.clearContents()
    pb.declareTypes([.string, .rtf], owner: nil)
    pb.setString(body, forType: .string)
    pb.setData(Data("{\\rtf1 \(body)}".utf8), forType: .rtf)
case "plainOnly":               // 纯文本
    pb.clearContents()
    pb.setString(body, forType: .string)
default: break
}
print("[\(mode)] written, changeCount=\(pb.changeCount)"); fflush(stdout)
Thread.sleep(forTimeInterval: 25)
