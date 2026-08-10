import AppKit
import Foundation
guard let item = NSPasteboard.general.pasteboardItems?.first else { exit(0) }
let pb = NSPasteboard.general

print("  ① item.availableType(from:) 逐类型探测（能否廉价筛掉？）")
for t in item.types {
    let t0 = CFAbsoluteTimeGetCurrent()
    let a = item.availableType(from: [t])
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "     %-40s %8.1fms → %@", (t.rawValue as NSString).utf8String!, ms,
        (a.map { $0.rawValue } ?? "nil") as NSString))
}

print("\n  ② pb.availableType(from: 全部类型)")
let t1 = CFAbsoluteTimeGetCurrent()
let best = pb.availableType(from: item.types)
print(String(format: "     %8.1fms → %@", (CFAbsoluteTimeGetCurrent()-t1)*1000,
    (best.map { $0.rawValue } ?? "nil") as NSString))

print("\n  ③ pb.readObjects(forClasses:)（系统自己的读取路径）")
let t2 = CFAbsoluteTimeGetCurrent()
let objs = pb.readObjects(forClasses: [NSAttributedString.self, NSString.self], options: nil)
print(String(format: "     %8.1fms → %d 个对象", (CFAbsoluteTimeGetCurrent()-t2)*1000, objs?.count ?? -1))

print("\n  ④ 直接读那个坏类型（对照，确认此进程未被缓存污染）")
let t3 = CFAbsoluteTimeGetCurrent()
let bad = item.data(forType: NSPasteboard.PasteboardType("public.utf16-external-plain-text"))
print(String(format: "     %8.1fms → %@", (CFAbsoluteTimeGetCurrent()-t3)*1000,
    (bad.map { "\($0.count)B" } ?? "nil") as NSString))
