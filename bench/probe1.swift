import AppKit
import Foundation
// 全新进程读一次（避开缓存），逐类型计时
guard let item = NSPasteboard.general.pasteboardItems?.first else { print("  空"); exit(0) }
for t in item.types {
    let t0 = CFAbsoluteTimeGetCurrent()
    let d = item.data(forType: t)
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "    %-40s %9.1fms %@%@", (t.rawValue as NSString).utf8String!, ms,
        (d.map { "\($0.count)B" } ?? "nil") as NSString, (ms > 200 ? "  ⚠️" : "") as NSString))
}
