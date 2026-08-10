import AppKit
import ApplicationServices
import Foundation

// Carbon Pasteboard API 能拿到每个 flavor 的标志位，NSPasteboard 拿不到
func flagNames(_ f: PasteboardFlavorFlags) -> String {
    var n: [String] = []
    if f.rawValue & 1   != 0 { n.append("SenderOnly") }
    if f.rawValue & 2   != 0 { n.append("SenderTranslated") }
    if f.rawValue & 4   != 0 { n.append("NotSaved") }
    if f.rawValue & 8   != 0 { n.append("RequestOnly") }
    if f.rawValue & 256 != 0 { n.append("★SystemTranslated") }
    if f.rawValue & 512 != 0 { n.append("★Promised") }
    return n.isEmpty ? "None" : n.joined(separator: "+")
}

var pb: Pasteboard?
guard PasteboardCreate("com.apple.pasteboard.clipboard" as CFString, &pb) == noErr, let pb else {
    print("PasteboardCreate 失败"); exit(1)
}
PasteboardSynchronize(pb)

var count: Int = 0
PasteboardGetItemCount(pb, &count)
print("Carbon 视角：\(count) 个 item\n")

let ns = NSPasteboard.general
let nsTypes = Set((ns.pasteboardItems?.first?.types ?? []).map { $0.rawValue })

for i in 1...max(1, Int(count)) {
    var itemID: PasteboardItemID?
    guard PasteboardGetItemIdentifier(pb, CFIndex(i), &itemID) == noErr, let itemID else { continue }
    var flavors: CFArray?
    guard PasteboardCopyItemFlavors(pb, itemID, &flavors) == noErr,
          let list = flavors as? [String] else { continue }

    print("item \(i)：\(list.count) 个 flavor")
    print("  \("flavor".padding(toLength: 42, withPad: " ", startingAt: 0))\("标志位".padding(toLength: 26, withPad: " ", startingAt: 0))NSPasteboard 也报告?")
    for f in list {
        var flags = PasteboardFlavorFlags(rawValue: 0)
        PasteboardGetItemFlavorFlags(pb, itemID, f as CFString, &flags)
        let inNS = nsTypes.contains(f) ? "是" : "否"
        print("  \(f.padding(toLength: 42, withPad: " ", startingAt: 0))"
            + "\(flagNames(flags).padding(toLength: 26, withPad: " ", startingAt: 0))\(inNS)")
    }
}
print("\nNSPasteboard 报告的类型：\(nsTypes.sorted().joined(separator: ", "))")
