import AppKit
import Vision
import Foundation

func render(lines: [String], size: NSSize, fontSize: CGFloat) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let f = NSFont(name: "Menlo", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    var y = size.height - 40
    for t in lines {
        y -= fontSize * 1.6
        NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1)])
            .draw(at: NSPoint(x: 40, y: y))
    }
    img.unlockFocus()
    return img
}
func cg(_ i: NSImage) -> CGImage { var r = NSRect(origin: .zero, size: i.size); return i.cgImage(forProposedRect: &r, context: nil, hints: nil)! }

func run(_ c: CGImage, level: VNRequestTextRecognitionLevel = .accurate, minH: Float? = nil, label: String) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = true
    if let m = minH { req.minimumTextHeight = m }
    let t0 = CFAbsoluteTimeGetCurrent()
    try? VNImageRequestHandler(cgImage: c, options: [:]).perform([req])
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    let n = req.results?.count ?? 0
    let chars = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().count
    print(String(format: "   %-46s %3d 块 %5d 字  %8.1fms", (label as NSString).utf8String!, n, chars, ms))
}

// ── 冷启动归因：同一张小图连跑 5 次 ──
let warm = cg(render(lines: ["warmup 预热 test 123"], size: NSSize(width: 600, height: 120), fontSize: 20))
print("=== 冷启动归因（同一张图连跑 5 次，accurate + zh/en）===")
for i in 1...5 { run(warm, label: "第 \(i) 次") }

print("\n=== 换语言组合是否触发二次模型加载 ===")
for langs in [["en-US"], ["zh-Hans"], ["ja-JP"], ["zh-Hans","en-US"]] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate; req.recognitionLanguages = langs; req.usesLanguageCorrection = true
    let t0 = CFAbsoluteTimeGetCurrent()
    try? VNImageRequestHandler(cgImage: warm, options: [:]).perform([req])
    print(String(format: "   langs=%-22s %8.1fms", (langs.joined(separator: "+") as NSString).utf8String!,
                 (CFAbsoluteTimeGetCurrent()-t0)*1000))
}

// ── 大图 0 块归因：minimumTextHeight 是不是元凶 ──
var lines: [String] = []
for i in 0..<45 { lines.append("\(i): 订单支付回调幂等 orderId=2606\(String(format: "%08d", i)) status=PAID 金额 \(i*37).50 元") }
let bigImg = render(lines: lines, size: NSSize(width: 3456, height: 2234), fontSize: 15)
let bigCG = cg(bigImg)
print("\n=== 大图 0 块归因 ===")
print("   NSImage 逻辑尺寸 \(Int(bigImg.size.width))×\(Int(bigImg.size.height)) pt")
print("   CGImage 实际像素 \(bigCG.width)×\(bigCG.height) px   (\(bigCG.height / Int(bigImg.size.height))x backing)")
print("   默认 minimumTextHeight = 1/32 图高 = \(Double(bigCG.height)/32.0) px；而 15pt 文字在 2x 下约 \(15*2) px")
print()
run(bigCG, label: "默认 minimumTextHeight")
for m: Float in [0.03, 0.01, 0.005, 0.001] { run(bigCG, minH: m, label: "minimumTextHeight=\(m)") }
run(bigCG, level: .fast, label: "fast 模式（默认 minH）")

// ── 降采样到常见截图尺寸再测 ──
print("\n=== 降采样后（accurate, minimumTextHeight=0.005）===")
for scale in [1.0, 0.5, 0.25] {
    let w = Int(Double(bigCG.width)*scale), h = Int(Double(bigCG.height)*scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    ctx.interpolationQuality = .high
    ctx.draw(bigCG, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let s = ctx.makeImage() else { continue }
    run(s, minH: 0.005, label: "\(w)×\(h) (\(Int(scale*100))%)")
}
