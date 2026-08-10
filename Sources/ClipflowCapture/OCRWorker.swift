import AppKit
import Foundation
import ImageIO
import ClipflowCore

/// OCR 后台工作者：从持久化队列取任务、识别、写回索引。
///
/// 设计约束（全部来自实测，见 `docs/03-图片OCR设计.md`）：
/// - **并发度 1**。Vision 内部串行：并发 1→8 加速仅 1.04x、CPU 恒定 ~0.95 核，
///   多线程零收益只增内存。
/// - **不阻塞入库**。图片先落库，OCR 排队慢慢做。
/// - **电池感知**。OCR 是本项目最耗电的操作，低电量模式下暂停。
/// - **失败有上限**。同一张图最多试 3 次，之后标记放弃，不无限重试烧电。
public actor OCRWorker {

    public struct Stats: Sendable {
        public var processed = 0
        public var recognized = 0
        public var noText = 0
        public var failed = 0
        public var lastError: String?
    }

    private let store: ClipflowStore
    private let service = OCRService()
    private var running = false
    private var task: Task<Void, Never>?
    public private(set) var stats = Stats()

    /// 同一张图最多试几次。超过就放弃 —— 反复重试一张识别不了的图只是在烧电。
    private let maxAttempts = 3
    /// 空闲轮询间隔。队列空时不必急着醒。
    private let idleInterval: UInt64 = 5_000_000_000

    public init(store: ClipflowStore) {
        self.store = store
    }

    public func start() {
        guard !running else { return }
        running = true
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while running, !Task.isCancelled {
            if Self.shouldPause() {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                continue
            }
            let did = await drainOnce()
            if !did {
                try? await Task.sleep(nanoseconds: idleInterval)
            }
        }
    }

    /// 处理一批。返回是否真的做了事，用来决定要不要睡。
    @discardableResult
    public func drainOnce(limit: Int = 5) async -> Bool {
        guard let jobs = try? store.pendingOCRJobs(limit: limit), !jobs.isEmpty else { return false }
        for job in jobs {
            guard running || jobs.count <= limit else { break }
            await process(job)
        }
        return true
    }

    private func process(_ job: ClipflowStore.OCRJob) async {
        stats.processed += 1

        guard job.attempts < maxAttempts else {
            try? store.failOCR(itemID: job.itemID, reason: "gave-up", giveUp: true)
            stats.failed += 1
            return
        }
        guard let cg = loadImage(job) else {
            try? store.failOCR(itemID: job.itemID, reason: "no-image", giveUp: true)
            stats.failed += 1
            return
        }

        guard let out = await service.recognize(cg), !out.isEmpty else {
            // 确认无文字：标记后不再重试。截图里没字是很常见的情况，不是失败。
            try? store.failOCR(itemID: job.itemID, reason: "no-text", giveUp: true)
            stats.noText += 1
            return
        }

        // ⚠️ OCR 会把截图里的密码变成明文可搜索字符串，绕过整个敏感内容策略。
        //    命中敏感规则的结果只存不索引。
        let sensitive = Self.looksSensitive(out.text)
        try? store.completeOCR(
            itemID: job.itemID,
            result: .init(text: out.text, engine: out.engine, confidence: out.confidence),
            sensitive: sensitive)
        stats.recognized += 1
    }

    private func loadImage(_ job: ClipflowStore.OCRJob) -> CGImage? {
        guard let reps = try? store.representations(of: job.itemID) else { return nil }
        // 优先用体积最小的图片表示，省解码开销
        let candidates = reps
            .filter { $0.uti.contains("png") || $0.uti.contains("jpeg")
                   || $0.uti.contains("tiff") || $0.uti.contains("heic") }
            .sorted { $0.byteSize < $1.byteSize }
        for r in candidates {
            guard let data = (try? store.data(of: r)) ?? nil,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            return img
        }
        return nil
    }

    /// 敏感判定。保守：宁可漏判，也不因误判把正常内容挡在搜索之外。
    static func looksSensitive(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(password|passwd|密码|口令)\b"#,
            #"(?i)\b(secret|api[_\s-]?key|access[_\s-]?token|私钥)\b"#,
            #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            "••••",
        ]
        let range = NSRange(text.startIndex..., in: text)
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               re.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    /// 低电量模式下暂停。OCR 是本项目最耗电的操作。
    static func shouldPause() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: 自检

    public func runSelfCheck() async -> (passed: Bool, detail: String) {
        await service.selfCheck()
    }
}
