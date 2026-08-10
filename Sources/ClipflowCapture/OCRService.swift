import AppKit
import Vision
import VisionKit
import CoreGraphics
import ClipflowCore

/// 图片文字识别。让截图里的文字可被搜索。
///
/// 实现严格按 `docs/03-图片OCR设计.md` 的实测结论，每一条都有数据支撑：
///
/// - **主路径用 VisionKit `ImageAnalyzer`**，不是底层的 `VNRecognizeTextRequest`。
///   实测 ImageAnalyzer 安全区更宽（9.0 MP / 2.4:1 都能过，VN accurate 不行）、
///   **无 15 秒冷启动**（VN accurate 全新进程首次 13,950 ms），识别字数还更多。
/// - **超安全区必须切网格，不能降采样**。降采样会等比缩小文字、跌破识别下限，
///   结果仍是 0；而"只切横条"保留了原宽度、长宽比更极端，同样失败（踩过）。
/// - **必须有兜底**：任何一层返回空都往下退，最后才判定"无文字"。
///   accurate 超限时是**静默返回空数组**，不报错 —— 一次空绝不能当成"没有文字"。
public struct OCRService: Sendable {

    /// 经验安全区：宽高比 < 2:1 且 ≤ 9 MP。ImageAnalyzer 比 VN accurate 宽松，
    /// 但 13 MP / 8.8:1 实测仍会空，所以留余量。
    public static let maxPixels = 9_000_000
    public static let maxAspect: Double = 2.0
    /// 小于这个边长基本是图标或表情，没有正文
    public static let minDimension = 100

    public struct Output: Sendable {
        public var text: String
        public var engine: String
        public var confidence: Double
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public init() {}

    /// 识别一张图。返回 nil 表示确认无文字（各层都试过了）。
    public func recognize(_ image: CGImage, locales: [String] = ["zh-Hans", "en-US"]) async -> Output? {
        guard min(image.width, image.height) >= Self.minDimension else { return nil }

        // ① 安全区内：ImageAnalyzer 直出
        if Self.withinSafeZone(image) {
            if let t = await Self.analyze(image, locales: locales), !t.isEmpty {
                return Output(text: t, engine: "ImageAnalyzer", confidence: 1)
            }
        } else {
            // ② 超安全区：切网格。每块保持文字原始像素高，这是它优于降采样的唯一原因。
            let tiles = Self.tileRects(width: image.width, height: image.height)
            var parts: [String] = []
            for rect in tiles {
                guard let sub = image.cropping(to: rect) else { continue }
                if let t = await Self.analyze(sub, locales: locales), !t.isEmpty {
                    parts.append(t)
                }
            }
            let merged = Self.mergeTiles(parts)
            if !merged.isEmpty {
                return Output(text: merged, engine: "ImageAnalyzer-tiled", confidence: 1)
            }
        }

        // ③ 兜底：VN fast。安全区更宽、文字下限更低，能捞回一部分。
        if let r = Self.visionFast(image, locales: locales), !r.text.isEmpty {
            return Output(text: r.text, engine: "Vision-fast", confidence: Double(r.confidence))
        }
        return nil
    }

    // MARK: 安全区与切块

    /// 小图不受长宽比约束 —— 极端长宽比只在大图上才导致识别失败。
    /// 一张 640×160 的窄条只有 0.1 MP，切块纯属自找麻烦（接缝还会劈开单词）。
    public static let aspectAppliesAbovePixels = 2_000_000

    public static func withinSafeZone(_ image: CGImage) -> Bool {
        let w = Double(image.width), h = Double(image.height)
        let pixels = Int(w * h)
        if pixels > maxPixels { return false }
        let aspect = max(w / h, h / w)
        if pixels > aspectAppliesAbovePixels, aspect >= maxAspect { return false }
        return true
    }

    /// 每轮切更长的那一边，自然收敛到近正方形，同时满足面积与宽高比两个约束。
    /// 重叠取 15%：接缝会把单词劈成两半（实测 "KUMQUAT7788" 被切成 "KUMQU" + "UAT7788"）。
    /// 重叠足够大时，完整单词至少会完整出现在某一块里，再靠合并阶段的子串去重把碎片丢掉。
    public static func tileRects(width: Int, height: Int, overlap: Double = 0.15) -> [CGRect] {
        var cols = 1, rows = 1
        var tw = width, th = height
        while tw * th > maxPixels
            || Double(tw) / Double(th) >= maxAspect
            || Double(th) / Double(tw) >= maxAspect {
            if tw >= th { cols += 1 } else { rows += 1 }
            tw = Int(ceil(Double(width) / Double(cols)))
            th = Int(ceil(Double(height) / Double(rows)))
            if cols > 32 || rows > 32 { break }
        }
        let ovx = Int(Double(tw) * overlap), ovy = Int(Double(th) * overlap)
        var rects: [CGRect] = []
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                rects.append(CGRect(x: x, y: y,
                                    width: min(tw + ovx, width - x),
                                    height: min(th + ovy, height - y)))
                x += tw
            }
            y += th
        }
        return rects
    }

    /// 合并各块结果。
    ///
    /// 两步：先按去空白后的内容去重（重叠区会产生完全相同的行），
    /// 再**丢掉被其它行包含的碎片** —— 接缝把单词劈开时，
    /// 完整的那份会出现在重叠更多的那一块里，碎片是它的子串。
    static func mergeTiles(_ parts: [String]) -> String {
        var seen = Set<String>()
        var lines: [(text: String, key: String)] = []
        for p in parts {
            for raw in p.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                let key = line.filter { !$0.isWhitespace }
                guard key.count > 1, !seen.contains(key) else { continue }
                seen.insert(key)
                lines.append((line, key))
            }
        }
        // 丢碎片：某行的 key 是另一行 key 的子串就丢掉（长的那份信息更全）
        let kept = lines.filter { candidate in
            !lines.contains { other in
                other.key.count > candidate.key.count && other.key.contains(candidate.key)
            }
        }
        return kept.map(\.text).joined(separator: "\n")
    }

    // MARK: 引擎

    @MainActor
    private static func analyze(_ image: CGImage, locales: [String]) async -> String? {
        guard ImageAnalyzer.isSupported else { return nil }
        var cfg = ImageAnalyzer.Configuration([.text])
        cfg.locales = locales
        guard let a = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: cfg)
        else { return nil }
        return a.transcript
    }

    /// VN fast 兜底。同步调用，放后台队列执行。
    static func visionFast(_ image: CGImage, locales: [String]) -> (text: String, confidence: Float)? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.recognitionLanguages = locales
        req.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil,
              let obs = req.results, !obs.isEmpty else { return nil }
        var lines: [String] = []
        var conf: Float = 0
        for o in obs {
            guard let c = o.topCandidates(1).first else { continue }
            lines.append(c.string)
            conf += c.confidence
        }
        guard !lines.isEmpty else { return nil }
        return (lines.joined(separator: "\n"), conf / Float(obs.count))
    }

    // MARK: 启动自检
    //
    // accurate 超限时静默返回空、不报错，是"代码在跑但什么都没索引"的典型形态。
    // 每次启动拿一张已知文字的图验一遍，识别不出就记日志告警。

    @MainActor
    public func selfCheck() async -> (passed: Bool, detail: String) {
        let expect = "Clipflow OCR 12345"
        guard let img = Self.canary(text: expect) else { return (false, "自检图生成失败") }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let out = await recognize(img) else {
            return (false, "识别为空 —— OCR 可能未生效")
        }
        let got = out.text.filter { !$0.isWhitespace }
        let ok = got.contains("12345")
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return (ok, ok ? "通过（\(out.engine)，\(Int(ms))ms）"
                       : "失败：期望含 12345，实得「\(got.prefix(40))」")
    }

    static func canary(text: String) -> CGImage? {
        let w = 640, h = 160
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.black,
        ]).draw(at: NSPoint(x: 30, y: 60))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
