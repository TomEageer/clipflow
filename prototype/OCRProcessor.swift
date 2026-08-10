//  OCRProcessor.swift
//  Clipflow — 图片 OCR 处理器（原型实现，可直接编译运行）
//
//  设计依据：docs/03-图片OCR设计.md
//  要点：异步不阻塞入库 / accurate→fast 双模式回退 / 启动 canary 自检 / 电池感知 / 内容去重

import Foundation
import Vision
import CoreGraphics
import AppKit

// MARK: - 结果模型

public struct OCROutcome: Sendable {
    public enum Status: String, Sendable {
        case recognized      // 识别出文字
        case noText          // 确认无文字（两种模式都空）
        case skipped         // 主动跳过（图太小 / 已处理过）
        case failed          // 引擎报错
    }
    public let status: Status
    public let text: String
    public let confidence: Float
    public let blocks: Int
    public let usedLevel: String       // "accurate" | "fast" | "-"
    public let didFallback: Bool       // 是否触发了回退（可观测指标）
    public let elapsedMs: Double
}

// MARK: - 配置

public struct OCRConfig: Sendable {
    /// 有中文内容时必须包含 zh-Hans，否则准确率从 100% 掉到 30%（实测）
    public var languages: [String] = ["zh-Hans", "en-US"]
    /// 小于此边长的图基本是图标/表情，不含正文
    public var minDimension: Int = 100
    /// 电池供电或低电量模式时暂停
    public var pauseOnBattery: Bool = true
    public var usesLanguageCorrection: Bool = true

    /// ⚠️ 实测硬约束：accurate 模式在 5.8~9.0 MP 之间开始静默返回空。
    /// 取 5.5 MP 留安全余量；超过则切块，**不能降采样**（降采样会让文字跌破 20~28px 下限）。
    public var maxPixelsAccurate: Int = 5_500_000
    /// 切块重叠比例，防止文字行正好被切断
    public var tileOverlap: Double = 0.05

    public init() {}
}

// MARK: - 处理器

public actor OCRProcessor {

    private let config: OCRConfig
    /// 已处理过的 blob hash，避免同一张图重复 OCR
    private var processed: Set<String> = []
    /// 可观测指标：空结果率异常升高是引擎静默失效的信号
    public private(set) var stats = Stats()

    public struct Stats: Sendable {
        public var total = 0, recognized = 0, noText = 0, skipped = 0, failed = 0, fallbacks = 0
        /// 空结果率——持续偏高说明引擎可能静默失效，需告警
        public var emptyRate: Double { total == 0 ? 0 : Double(noText) / Double(total) }
    }

    public init(config: OCRConfig = OCRConfig()) {
        self.config = config
    }

    // MARK: 主入口

    /// 对一张图做 OCR。contentHash 用于去重（传 blob 的 SHA-256）
    public func recognize(_ image: CGImage, contentHash: String? = nil) -> OCROutcome {
        let t0 = CFAbsoluteTimeGetCurrent()
        stats.total += 1

        // ① 去重：同一张图只 OCR 一次
        if let h = contentHash, processed.contains(h) {
            stats.skipped += 1
            return OCROutcome(status: .skipped, text: "", confidence: 0, blocks: 0,
                              usedLevel: "-", didFallback: false,
                              elapsedMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        // ② 跳过小图（图标、表情、色块）
        if min(image.width, image.height) < config.minDimension {
            stats.skipped += 1
            return OCROutcome(status: .skipped, text: "", confidence: 0, blocks: 0,
                              usedLevel: "-", didFallback: false,
                              elapsedMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        // ③ 判定顺序（依据实测的两条硬约束，见 docs/03 §2.1）：
        //      accurate 直出 → 超 5.5MP 则切块 accurate → 仍空则 fast → 仍空则 no_text
        var didFallback = false
        let pixels = image.width * image.height
        var result: Raw

        if pixels <= config.maxPixelsAccurate {
            result = perform(image, level: .accurate)
        } else {
            // 超出 accurate 画布上限 → 切块。
            // ⚠️ 绝不用降采样：降采样会等比缩小文字，跌破 accurate 的 20~28px 文字高下限，
            //    结果依然是 0 块（早期实测已验证 50%/25% 降采样全部失败）。
            result = performTiled(image)
        }

        // ④ ⚠️ 静默失效防线：accurate 超限时返回空数组且不报错（耗时会骤降到 ~45ms）。
        //    绝不把"一次空"当成"没有文字"，必须用 fast 复核（其画布上限 ~17.6MP、文字下限 10~14px，都更宽松）。
        if result.blocks == 0 {
            didFallback = true
            stats.fallbacks += 1
            result = perform(image, level: .fast)
        }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        if result.error != nil {
            stats.failed += 1
            return OCROutcome(status: .failed, text: "", confidence: 0, blocks: 0,
                              usedLevel: result.level, didFallback: didFallback,
                              elapsedMs: ms)
        }
        if result.blocks == 0 {
            stats.noText += 1
            return OCROutcome(status: .noText, text: "", confidence: 0, blocks: 0,
                              usedLevel: result.level, didFallback: didFallback, elapsedMs: ms)
        }

        if let h = contentHash { processed.insert(h) }
        stats.recognized += 1
        return OCROutcome(status: .recognized, text: result.text, confidence: result.confidence,
                          blocks: result.blocks, usedLevel: result.level,
                          didFallback: didFallback, elapsedMs: ms)
    }

    // MARK: 单次 Vision 调用

    private struct Raw { let text: String; let blocks: Int; let confidence: Float; let level: String; let error: Error? }

    private func perform(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> Raw {
        let name = level == .accurate ? "accurate" : "fast"
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.recognitionLanguages = config.languages
        req.usesLanguageCorrection = config.usesLanguageCorrection

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        } catch {
            return Raw(text: "", blocks: 0, confidence: 0, level: name, error: error)
        }

        let obs = req.results ?? []
        var lines: [String] = []
        var conf: Float = 0
        for o in obs {
            guard let c = o.topCandidates(1).first else { continue }
            lines.append(c.string)
            conf += c.confidence
        }
        return Raw(text: lines.joined(separator: "\n"), blocks: obs.count,
                   confidence: obs.isEmpty ? 0 : conf / Float(obs.count), level: name, error: nil)
    }

    // MARK: 大图切块（保持文字原始像素高度）

    /// 把超过 accurate 画布上限的大图切成若干块分别识别，再按位置合并。
    /// 关键：切块**不改变文字的像素高度**，这是它优于降采样的唯一原因。
    ///
    /// 注：块之间**串行**处理。实测 Vision 内部串行化，并发度 1→8 加速仅 1.04x、
    /// CPU 恒定 ~0.95 核，多线程零收益只增内存。
    private func performTiled(_ image: CGImage) -> Raw {
        let tiles = Self.tileRects(width: image.width, height: image.height,
                                   maxPixels: config.maxPixelsAccurate, overlap: config.tileOverlap)
        var collected: [(y: Int, x: Int, text: String, conf: Float)] = []
        var blocks = 0

        for rect in tiles {
            guard let sub = image.cropping(to: rect) else { continue }
            let r = perform(sub, level: .accurate)
            if r.blocks == 0 { continue }
            blocks += r.blocks
            // 记录块在原图中的位置，用于按阅读顺序还原
            collected.append((Int(rect.minY), Int(rect.minX), r.text, r.confidence))
        }

        guard !collected.isEmpty else {
            return Raw(text: "", blocks: 0, confidence: 0, level: "accurate-tiled", error: nil)
        }

        // 按原图坐标排序还原阅读顺序（先上后下、先左后右）
        collected.sort { $0.y == $1.y ? $0.x < $1.x : $0.y > $1.y }

        // 重叠区会产生重复行，按行去重（保序）
        var seen = Set<String>()
        var lines: [String] = []
        for c in collected {
            for line in c.text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                let key = s.trimmingCharacters(in: .whitespaces)
                if key.isEmpty || seen.contains(key) { continue }
                seen.insert(key)
                lines.append(s)
            }
        }
        let conf = collected.reduce(Float(0)) { $0 + $1.conf } / Float(collected.count)
        return Raw(text: lines.joined(separator: "\n"), blocks: blocks,
                   confidence: conf, level: "accurate-tiled", error: nil)
    }

    /// 计算切块矩形 —— **必须切成网格，不能只切横条**。
    ///
    /// 实测经验安全区（见 docs/03 §2.1）：**宽高比 < 2:1 且面积 ≤ 6.4 MP** 时 accurate 稳定工作。
    /// 关键反例：6912×782（5.4MP 但 8.8:1）→ 0 块；3600×1500（5.4MP, 2.4:1）→ 0 块；
    ///          而 1500×3600（同样 5.4MP，0.4:1 竖长）→ 175 块正常。
    /// 所以只按高度切横条会保留原图宽度、长宽比更极端，**必然失败**（早期原型踩过）。
    nonisolated static func tileRects(width: Int, height: Int, maxPixels: Int, overlap: Double) -> [CGRect] {
        let maxAspect = 2.0
        let aspect = Double(width) / Double(height)
        if width * height <= maxPixels && aspect < maxAspect && aspect > 1.0 / maxAspect {
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }

        // 每轮切更长的那一边，自然收敛到近正方形 → 同时满足面积与宽高比两个约束。
        // 6912×4468 会收敛到 3 列 × 2 行 = 2304×2234（5.15MP，宽高比 1.03），已实测该配置有效。
        var cols = 1, rows = 1
        var tw = width, th = height
        while tw * th > maxPixels || Double(tw) / Double(th) >= maxAspect || Double(th) / Double(tw) >= maxAspect {
            if tw >= th { cols += 1 } else { rows += 1 }
            tw = Int(ceil(Double(width) / Double(cols)))
            th = Int(ceil(Double(height) / Double(rows)))
            if cols > 64 || rows > 64 { break }   // 病态输入兜底
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

    // MARK: ⚠️ 启动自检 canary
    //
    // 目的：防止"代码在跑、测试也过、生产上什么都没索引"的静默失效。
    // 每次启动用一张内置的已知文字图跑一遍，识别不出就告警。

    public func selfCheck() -> (passed: Bool, detail: String) {
        let expect = "Clipflow OCR 自检 12345"
        guard let img = Self.canaryImage(text: expect) else {
            return (false, "canary 图像生成失败")
        }
        let r = recognize(img)
        // 自检不计入业务统计
        stats.total -= 1
        if r.status == .recognized { stats.recognized -= 1 }
        else if r.status == .noText { stats.noText -= 1 }
        if r.didFallback { stats.fallbacks -= 1 }

        let got = r.text.filter { !$0.isWhitespace }
        let want = expect.filter { !$0.isWhitespace }
        let hit = got.contains("12345") && got.contains("Clipflow")
        return (hit, hit
                ? "通过（\(r.usedLevel)\(r.didFallback ? " · 已回退" : "")，\(String(format: "%.0f", r.elapsedMs))ms）"
                : "失败：期望含「\(want)」，实得「\(got.prefix(40))」")
    }

    nonisolated static func canaryImage(text: String) -> CGImage? {
        let size = NSSize(width: 640, height: 160)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.black
        ]).draw(at: NSPoint(x: 30, y: 60))
        img.unlockFocus()
        var r = NSRect(origin: .zero, size: size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    // MARK: 电池感知

    nonisolated public static func shouldPause(_ config: OCRConfig) -> Bool {
        guard config.pauseOnBattery else { return false }
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
