import AppKit
import Foundation
// 关键差异：写完后**跑 run loop**（真实 App 的行为），而不是 Thread.sleep
let pb = NSPasteboard.general
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "runloop"
pb.clearContents()
let a = NSAttributedString(string: String(repeating: "分布式锁必须用 SETNX 原子操作。", count: 40),
    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.systemRed])
pb.writeObjects([a])
print("written(\(mode)) changeCount=\(pb.changeCount)"); fflush(stdout)
if mode == "runloop" {
    RunLoop.current.run(until: Date().addingTimeInterval(30))   // 真实 App：run loop 在转
} else {
    Thread.sleep(forTimeInterval: 30)                            // 我之前的写法：run loop 死的
}
