import AppKit
import Vision
import Foundation

// ── 造贴近真实的「截图」：给定行文本，渲染成图 ──────────────────
func render(lines: [(String, NSFont, NSColor)], size: NSSize, bg: NSColor, pad: CGFloat = 40) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    bg.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    var y = size.height - pad
    for (text, font, color) in lines {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attrs)
        y -= font.pointSize * 1.6
        s.draw(at: NSPoint(x: pad, y: y))
    }
    img.unlockFocus()
    return img
}

func cgImage(_ img: NSImage) -> CGImage? {
    var r = NSRect(origin: .zero, size: img.size)
    return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
}

// ── OCR ────────────────────────────────────────────────────────
struct OCRResult { let text: String; let ms: Double; let blocks: Int; let avgConf: Float }

func ocr(_ cg: CGImage, level: VNRequestTextRecognitionLevel, langs: [String], correction: Bool) -> OCRResult? {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.recognitionLanguages = langs
    req.usesLanguageCorrection = correction
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let t0 = CFAbsoluteTimeGetCurrent()
    do { try handler.perform([req]) } catch { print("  OCR 失败: \(error)"); return nil }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    guard let obs = req.results else { return nil }
    var out: [String] = []; var conf: Float = 0
    for o in obs {
        if let c = o.topCandidates(1).first { out.append(c.string); conf += c.confidence }
    }
    return OCRResult(text: out.joined(separator: "\n"), ms: ms,
                     blocks: obs.count, avgConf: obs.isEmpty ? 0 : conf / Float(obs.count))
}

// 字符级准确率（去空白后比对，用最长公共子序列比例）
func accuracy(truth: String, got: String) -> Double {
    let a = Array(truth.filter { !$0.isWhitespace })
    let b = Array(got.filter { !$0.isWhitespace })
    if a.isEmpty { return 0 }
    var prev = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        var cur = [Int](repeating: 0, count: b.count + 1)
        for j in 1...max(b.count, 1) where b.count > 0 {
            cur[j] = a[i-1] == b[j-1] ? prev[j-1] + 1 : max(prev[j], cur[j-1])
        }
        prev = cur
    }
    return Double(prev[b.count]) / Double(a.count)
}

print("Vision 支持的识别语言（accurate）:")
let probe = VNRecognizeTextRequest(); probe.recognitionLevel = .accurate
let supported = (try? probe.supportedRecognitionLanguages()) ?? []
print("  \(supported.joined(separator: ", "))\n")

let mono = NSFont(name: "Menlo", size: 15) ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
let monoSmall = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
let ui = NSFont.systemFont(ofSize: 16)

// 场景 1：IDE 代码截图（深色）
let s1lines = [
    "public void handlePayCallback(PayNotifyVO vo) {",
    "    if (!DistributedLock.lock(LOCK_KEY + vo.getOrderId(), 30)) {",
    "        log.warn(\"重复回调已拦截 orderId={}\", vo.getOrderId());",
    "        return;",
    "    }",
    "    payService.process(vo);",
    "}"
]
let s1truth = s1lines.joined()

// 场景 2：中文文档截图（浅色）
let s2lines = [
    "订单支付回调必须保证幂等性，不能依赖第三方防重。",
    "分布式锁必须使用 SETNX 原子操作，禁止 getValue + setValue 伪锁。",
    "生产库地址：api.internal.example.com，网关端口 8443。",
    "联系人：张三，工号 10000001。"
]
let s2truth = s2lines.joined()

// 场景 3：终端日志小字（最难：11pt 等宽 + 大量符号数字）
let s3lines = [
    "2026-08-10 11:35:02.441 [http-nio-8080-exec-7] ERROR c.e.p.OrderService",
    "  trackID=trace-20262200563992045 orderId=2606221553146739546i402702",
    "  supplier returned code=402 msg=订单不存在 elapsed=1284ms",
    "  at com.example.pay.PaymentService.doGetPayUrl(PayOpenBusinessImpl.java:21)"
]
let s3truth = s3lines.joined()

let cases: [(String, NSImage, String)] = [
    ("① IDE 代码（15pt 深色）", render(lines: s1lines.map { ($0, mono, NSColor(calibratedWhite: 0.88, alpha: 1)) },
                                  size: NSSize(width: 1400, height: 420), bg: NSColor(calibratedWhite: 0.13, alpha: 1)), s1truth),
    ("② 中文文档（16pt 浅色）", render(lines: s2lines.map { ($0, ui, NSColor(calibratedWhite: 0.12, alpha: 1)) },
                                  size: NSSize(width: 1400, height: 330), bg: NSColor(calibratedWhite: 0.98, alpha: 1)), s2truth),
    ("③ 终端日志（11pt 小字）", render(lines: s3lines.map { ($0, monoSmall, NSColor(calibratedWhite: 0.9, alpha: 1)) },
                                  size: NSSize(width: 1400, height: 260), bg: NSColor(calibratedWhite: 0.08, alpha: 1)), s3truth)
]

let configs: [(String, VNRequestTextRecognitionLevel, [String], Bool)] = [
    ("accurate + zh/en + 纠错", .accurate, ["zh-Hans", "en-US"], true),
    ("accurate + zh/en 无纠错", .accurate, ["zh-Hans", "en-US"], false),
    ("fast + zh/en", .fast, ["zh-Hans", "en-US"], true),
    ("accurate + 仅 en", .accurate, ["en-US"], true),
]

for (name, img, truth) in cases {
    guard let cg = cgImage(img) else { continue }
    print("── \(name)   \(cg.width)×\(cg.height)")
    for (cname, level, langs, corr) in configs {
        guard let r = ocr(cg, level: level, langs: langs, correction: corr) else { continue }
        let acc = accuracy(truth: truth, got: r.text)
        print(String(format: "   %-24s 准确率 %5.1f%%   %7.1fms   %2d 块   置信 %.2f",
                     (cname as NSString).utf8String!, acc * 100, r.ms, r.blocks, r.avgConf))
    }
    print()
}

// ── 大图性能：3456×2234 全屏截图尺寸 ────────────────────────────
print("── 全屏截图尺寸性能测试（3456×2234）")
var big: [(String, NSFont, NSColor)] = []
for i in 0..<45 {
    big.append(("\(i): 订单支付回调幂等校验 orderId=2606\(String(format: "%08d", i)) status=PAID 金额 \(i * 37).50 元",
                mono, NSColor(calibratedWhite: 0.88, alpha: 1)))
}
let bigImg = render(lines: big, size: NSSize(width: 3456, height: 2234), bg: NSColor(calibratedWhite: 0.13, alpha: 1))
if let cg = cgImage(bigImg) {
    for (cname, level, langs, corr) in configs.prefix(3) {
        if let r = ocr(cg, level: level, langs: langs, correction: corr) {
            print(String(format: "   %-24s %8.1fms   %3d 块   识别出 %d 字",
                         (cname as NSString).utf8String!, r.ms, r.blocks, r.text.count))
        }
    }
    // 降采样后再 OCR：省时间但会不会掉精度
    print("\n   降采样对比（大图先缩小再 OCR）:")
    for scale in [0.75, 0.5, 0.33] {
        let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { continue }
        if let r = ocr(small, level: .accurate, langs: ["zh-Hans", "en-US"], correction: true) {
            print(String(format: "     %.0f%% (%d×%d)  %8.1fms  %3d 块  %d 字",
                         scale * 100, w, h, r.ms, r.blocks, r.text.count))
        }
    }
}
