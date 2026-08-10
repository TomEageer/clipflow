import AppKit
import ApplicationServices
import Foundation

var pbRef: Pasteboard?
guard PasteboardCreate("com.apple.pasteboard.clipboard" as CFString, &pbRef) == noErr, let pbRef else { exit(1) }
PasteboardSynchronize(pbRef)
var count: Int = 0
PasteboardGetItemCount(pbRef, &count)
var itemID: PasteboardItemID?
PasteboardGetItemIdentifier(pbRef, 1, &itemID)
var flavors: CFArray?
PasteboardCopyItemFlavors(pbRef, itemID!, &flavors)
let list = (flavors as? [String]) ?? []

print("═══ A. Carbon PasteboardCopyItemFlavorData ═══")
for f in list {
    var data: CFData?
    let t0 = CFAbsoluteTimeGetCurrent()
    let st = PasteboardCopyItemFlavorData(pbRef, itemID!, f as CFString, &data)
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    let n = data.map { ($0 as Data).count }
    print(String(format: "  %-42s %9.1fms  status=%d  %@%@",
        (f as NSString).utf8String!, ms, st,
        (n.map { "\($0)B" } ?? "nil") as NSString,
        (ms > 200 ? "  ⚠️ 阻塞!" : "") as NSString))
}

print("\n═══ B. NSPasteboardItem.data(forType:) ═══")
guard let item = NSPasteboard.general.pasteboardItems?.first else { exit(0) }
for t in item.types {
    let t0 = CFAbsoluteTimeGetCurrent()
    let d = item.data(forType: t)
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "  %-42s %9.1fms  %@%@",
        (t.rawValue as NSString).utf8String!, ms,
        (d.map { "\($0.count)B" } ?? "nil") as NSString,
        (ms > 200 ? "  ⚠️ 阻塞!" : "") as NSString))
}

print("\n═══ C. NSPasteboard.data(forType:)（pasteboard 级，非 item 级）═══")
let pb = NSPasteboard.general
for t in (pb.types ?? []) {
    let t0 = CFAbsoluteTimeGetCurrent()
    let d = pb.data(forType: t)
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "  %-42s %9.1fms  %@%@",
        (t.rawValue as NSString).utf8String!, ms,
        (d.map { "\($0.count)B" } ?? "nil") as NSString,
        (ms > 200 ? "  ⚠️ 阻塞!" : "") as NSString))
}
