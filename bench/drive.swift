import AppKit; import Vision; import Foundation

func makeImage(pxW: Int, pxH: Int, textPx: CGFloat, lines: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.13, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
    let n = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = n
    let f = NSFont(name: "Menlo", size: textPx)!
    var y = CGFloat(pxH) - textPx*2
    for k in 0..<lines { if y < textPx { break }
        NSAttributedString(string: "\(k): 订单支付回调幂等 orderId=2606\(String(format: "%08d", k)) status=PAID 金额 \(k*37).50 元",
            attributes: [.font: f, .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)]).draw(at: NSPoint(x: 24, y: y))
        y -= textPx*1.7 }
    NSGraphicsContext.restoreGraphicsState(); return ctx.makeImage()!
}

@main struct Drive {
    static func main() async {
        let p = OCRProcessor()
        print("① 启动自检 canary")
        let sc = await p.selfCheck(); print("   \(sc.passed ? "✅ " : "❌ ")\(sc.detail)\n")

        print("② 切块规划（6912×4468 = 30.9MP，上限 5.5MP）")
        for (i, r) in OCRProcessor.tileRects(width: 6912, height: 4468, maxPixels: 5_500_000, overlap: 0.05).enumerated() {
            print("   块\(i+1): \(Int(r.width))×\(Int(r.height)) @y=\(Int(r.minY))  = \(String(format:"%.1f", Double(Int(r.width)*Int(r.height))/1e6))MP")
        }

        print("\n③ 实跑 30.9MP 全屏图，文字 30px（此前 accurate 直出 = 0 块）")
        let big = makeImage(pxW: 6912, pxH: 4468, textPx: 30, lines: 85)
        let r = await p.recognize(big, contentHash: "big-1")
        print("   状态=\(r.status.rawValue)  模式=\(r.usedLevel)  回退=\(r.didFallback)  块=\(r.blocks)  字=\(r.text.count)  耗时=\(String(format:"%.0f", r.elapsedMs))ms")
        print("   首行: \(String(r.text.split(separator:"\n").first ?? "").prefix(70))")

        print("\n④ 去重验证：同一张图再跑")
        let r2 = await p.recognize(big, contentHash: "big-1")
        print("   状态=\(r2.status.rawValue)  耗时=\(String(format:"%.2f", r2.elapsedMs))ms")

        print("\n⑤ 小图跳过验证（64×64 图标）")
        let tiny = makeImage(pxW: 64, pxH: 64, textPx: 10, lines: 2)
        let r3 = await p.recognize(tiny)
        print("   状态=\(r3.status.rawValue)")

        let s = await p.stats
        print("\n⑥ 指标: 总\(s.total) 识别\(s.recognized) 无文字\(s.noText) 跳过\(s.skipped) 失败\(s.failed) 回退\(s.fallbacks) 空结果率\(String(format:"%.0f%%", s.emptyRate*100))")
    }
}
