import AppKit
import Vision
import Foundation
import Darwin

func residentMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
}
func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }

/// 直接用 CGContext 造图（1x，像素=点，避免 Retina 2x 干扰）
func makeImage(pxW: Int, pxH: Int, textPx: CGFloat, lines: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
    let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = nsctx
    let font = NSFont(name: "Menlo", size: textPx) ?? .monospacedSystemFont(ofSize: textPx, weight: .regular)
    var y = CGFloat(pxH) - textPx * 2
    for k in 0..<lines {
        if y < textPx { break }
        NSAttributedString(string: "\(k): 订单支付回调幂等 orderId=2606\(String(format: "%08d", k)) status=PAID 金额 \(k*37).50 元",
                           attributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)])
            .draw(at: NSPoint(x: 24, y: y))
        y -= textPx * 1.7
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func ocr(_ c: CGImage, _ level: VNRequestTextRecognitionLevel) -> (Int, Int, Double) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = true
    let t0 = CFAbsoluteTimeGetCurrent()
    try? VNImageRequestHandler(cgImage: c, options: [:]).perform([req])
    let ms = (CFAbsoluteTimeGetCurrent()-t0)*1000
    let obs = req.results ?? []
    return (obs.count, obs.compactMap { $0.topCandidates(1).first?.string }.joined().count, ms)
}

// 预热
_ = ocr(makeImage(pxW: 600, pxH: 200, textPx: 24, lines: 3), .accurate)
_ = ocr(makeImage(pxW: 600, pxH: 200, textPx: 24, lines: 3), .fast)

print("═══ 诊断 1：accurate 静默返回空的边界（文字绝对像素高固定 28px，只变画布大小）═══")
print("   画布           百万像素   accurate(块/字/耗时)      fast(块/字/耗时)")
for (w, h) in [(1600,900),(2400,1350),(3200,1800),(4000,2250),(4800,2700),(5600,3150),(6912,4468),(8000,4500)] {
    autoreleasepool {
        let lines = max(3, h / 50)
        let img = makeImage(pxW: w, pxH: h, textPx: 28, lines: lines)
        let a = ocr(img, .accurate), b = ocr(img, .fast)
        let mp = Double(w*h)/1_000_000
        let flag = a.0 == 0 ? "  ← accurate 空!" : ""
        print("   \(w)×\(h)".padding(toLength: 16, withPad: " ", startingAt: 0)
              + f(mp,1).padding(toLength: 10, withPad: " ", startingAt: 0)
              + "\(a.0)块 \(a.1)字 \(f(a.2,0))ms".padding(toLength: 26, withPad: " ", startingAt: 0)
              + "\(b.0)块 \(b.1)字 \(f(b.2,0))ms" + flag)
    }
}

print("\n═══ 诊断 2：文字绝对像素高的下限（画布固定 3200×1800）═══")
print("   文字高   accurate(块/字)     fast(块/字)")
for tp: CGFloat in [40, 28, 20, 14, 10, 8, 6] {
    autoreleasepool {
        let img = makeImage(pxW: 3200, pxH: 1800, textPx: tp, lines: Int(1700 / (tp*1.7)))
        let a = ocr(img, .accurate), b = ocr(img, .fast)
        print("   \(Int(tp))px".padding(toLength: 9, withPad: " ", startingAt: 0)
              + "\(a.0)块 \(a.1)字".padding(toLength: 20, withPad: " ", startingAt: 0)
              + "\(b.0)块 \(b.1)字" + (a.0 == 0 ? "  ← accurate 空!" : ""))
    }
}

print("\n═══ 诊断 3：内存到底泄不泄漏（加 autoreleasepool 重测）═══")
print("   —— 对照组 A：只造图不 OCR（隔离出图像本身的内存）")
var base = residentMB()
print("   起始 \(f(base)) MB")
for k in 1...10 {
    autoreleasepool { _ = makeImage(pxW: 6912, pxH: 4468, textPx: 30, lines: 45) }
    if k % 5 == 0 { print("   第 \(k) 张后：\(f(residentMB())) MB（净增 \(f(residentMB()-base)) MB）") }
}
print("   A 组净增 \(f(residentMB()-base)) MB\n")

print("   —— 对照组 B：造图 + OCR（fast）")
base = residentMB()
print("   起始 \(f(base)) MB")
for k in 1...10 {
    autoreleasepool {
        let img = makeImage(pxW: 6912, pxH: 4468, textPx: 30, lines: 45)
        _ = ocr(img, .fast)
    }
    if k % 5 == 0 { print("   第 \(k) 张后：\(f(residentMB())) MB（净增 \(f(residentMB()-base)) MB）") }
}
print("   B 组净增 \(f(residentMB()-base)) MB")
print("\n   判定：B-A 才是 OCR 自身的内存增量；若 A 已经很大，说明是图像本身而非 Vision 泄漏")
