import AppKit
import Foundation
import ClipflowCore

/// 剪贴板捕获源。抽象成协议是为了将来接别的来源（网络、iOS）而不动下游。
public protocol ClipSource: Sendable {
    func start() -> AsyncStream<RawSnapshot>
    func stop()
}

/// 本机剪贴板轮询捕获。
///
/// **macOS 没有剪贴板变更通知** —— 没有 NSNotification、没有 KVO、没有回调。
/// 唯一可行的办法是轮询 `NSPasteboard.general.changeCount`（一个每次变更就自增的整数）。
public final class PasteboardWatcher: ClipSource, @unchecked Sendable {

    public struct Config: Sendable {
        /// 活跃时轮询间隔。Maccy 用 0.5s；200ms 在 M 系上 CPU 仍 < 0.3%，跟手度差别明显。
        public var activeInterval: TimeInterval = 0.2
        /// 系统空闲超过 idleThreshold 后降频，省电
        public var idleInterval: TimeInterval = 1.0
        public var idleThreshold: TimeInterval = 60
        /// 单条上限，超过只记元数据不取数据
        public var maxBytesPerItem = 100 * 1024 * 1024

        public init() {}
    }

    private let config: Config
    private let pasteboard: NSPasteboard
    private let lock = NSLock()
    private var lastChangeCount: Int
    /// 我们自己写回剪贴板时记下 changeCount，下一轮跳过 —— 否则会捕获到自己粘贴的内容，形成回声
    private var suppressedChangeCounts = Set<Int>()
    private var running = false
    private var timerTask: Task<Void, Never>?

    public init(pasteboard: NSPasteboard = .general, config: Config = Config()) {
        self.pasteboard = pasteboard
        self.config = config
        self.lastChangeCount = pasteboard.changeCount
    }

    /// 自己写剪贴板后调用，抑制随之而来的那次变更
    public func suppressNextChange() {
        lock.lock(); defer { lock.unlock() }
        // 写入后 changeCount 会 +1，但不保证精确，宽容记录附近几个值
        let c = pasteboard.changeCount
        for d in 0...2 { suppressedChangeCounts.insert(c + d) }
    }

    public func start() -> AsyncStream<RawSnapshot> {
        lock.lock(); running = true; lock.unlock()

        // ⚠️ 读取**必须与检测同步**，不能甩到别的队列延后执行。
        //
        // 剪贴板内容是**瞬态**的：系统只保存"当前"一份，不留历史。
        // 延后读取时若剪贴板已翻页，读到的是新内容却被记在旧那次变更上 —— **张冠李戴**。
        // 实测验证过这个错法：连续 7 次复制，异步读把后 5 次全读成了最后一条。
        //
        // 所以取舍是「宁可漏，不可错」：读取慢（实测可达 4143ms）时会漏掉期间的变更，
        // 但绝不会记错内容。对剪贴板管理器，记错比漏记严重得多。
        //
        // 现实中这不是问题：正常使用下读取是 0.1ms 级，只有另一个进程在毫秒级狂写时才会阻塞。
        // 慢读取次数通过 slowReadCount 暴露出来，便于发现是哪个 App 在拖慢捕获。
        return AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isRunning else { break }

                    if self.hasChanged() {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        let snap = self.readCurrent()
                        self.recordRead(ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                        if let snap { continuation.yield(snap) }
                    }

                    let interval = self.currentInterval()
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            self.lock.lock(); self.timerTask = task; self.lock.unlock()
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        lock.lock()
        running = false
        timerTask?.cancel()
        timerTask = nil
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 自适应节流：系统空闲久了降频省电
    private func currentInterval() -> TimeInterval {
        let idle = Self.systemIdleSeconds()
        return idle > config.idleThreshold ? config.idleInterval : config.activeInterval
    }

    /// 检测剪贴板是否发生了我们该处理的变更。**只比 changeCount，绝不读内容。**
    ///
    /// ⚠️ 这是热路径，必须廉价且永不阻塞。读内容要走 `readCurrent()`，原因见下。
    public func hasChanged() -> Bool {
        let current = pasteboard.changeCount
        lock.lock(); defer { lock.unlock() }
        guard current != lastChangeCount else { return false }
        lastChangeCount = current
        if suppressedChangeCounts.contains(current) {
            suppressedChangeCounts.remove(current)
            return false
        }
        return true
    }

    /// 读取当前剪贴板内容。
    ///
    /// ⚠️ **这个调用可能阻塞数秒。** 实测：另一个进程正在频繁写剪贴板时，
    /// 本调用曾耗时 **4143ms**（源进程独占/lazy provider 等待）。
    /// 所以它绝不能出现在轮询循环里 —— 必须甩到独立队列。
    public func readCurrent() -> RawSnapshot? {
        Self.snapshot(from: pasteboard, maxBytes: config.maxBytesPerItem)
    }

    /// 同步版：检测 + 读取。仅供调试/测试用，生产路径请用 `start()`。
    public func pollOnce() -> RawSnapshot? {
        guard hasChanged() else { return nil }
        return readCurrent()
    }

    /// 可观测指标：慢读取次数。持续升高说明有 App 在拖慢捕获。
    public private(set) var slowReadCount = 0
    public private(set) var lastReadMs: Double = 0

    /// NSLock 在 async 上下文不可直接用，加锁收进同步方法。
    private func recordRead(ms: Double) {
        lock.lock()
        lastReadMs = ms
        if ms > 500 { slowReadCount += 1 }
        lock.unlock()
    }

    public var readStats: (slow: Int, lastMs: Double) {
        lock.lock(); defer { lock.unlock() }
        return (slowReadCount, lastReadMs)
    }

    // MARK: - NSPasteboard → RawSnapshot

    /// 已知的「承诺型/可派生」类型 —— **必须跳过，读它们会阻塞十几秒**。
    ///
    /// 实测（跨进程读一次普通富文本复制）：
    /// ```
    /// public.utf8-plain-text                0.3ms   1720B
    /// public.html                           0.1ms   1740B
    /// public.rtf                            0.1ms   1728B
    /// public.utf16-external-plain-text  18493.3ms   nil   ← 阻塞 18.5 秒后返回 nil
    /// ```
    /// 写入方声明了这个类型却从不提供数据，读取方一路等到系统超时。
    /// 而它的内容完全可以从 utf8 派生，跳过零损失。
    public static let skippedTypes: Set<String> = [
        "public.utf16-external-plain-text",
        "public.utf16-plain-text",
        "NSStringPboardType",              // utf8 的老别名
        "CorePasteboardFlavorType 0x75747874",
    ]

    /// 单个类型的读取超时。超过就放弃这个类型，保住整体捕获不被拖死。
    public static let perTypeTimeout: TimeInterval = 0.3

    /// 读取当前剪贴板的全部 representation。
    ///
    /// ⚠️ 必须在 changeCount 变更后**立即**读：部分 App 用 lazy pasteboard provider，
    /// 内容是被读取时才生成的，读取时机错了就拿到空。
    ///
    /// ⚠️ 同时必须防阻塞：跳过已知承诺型类型 + 对每个类型加超时看门狗。
    /// 只靠跳过列表不够 —— 列不全所有会阻塞的类型，看门狗兜住未知的。
    public static func snapshot(from pb: NSPasteboard, maxBytes: Int) -> RawSnapshot? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }

        var reps: [(uti: String, data: Data)] = []
        var total = 0

        for item in items {
            for type in item.types {
                if skippedTypes.contains(type.rawValue) { continue }

                switch readWithTimeout(item, type) {
                case .timedOut:
                    // 记下类型名但不带数据，保留「这个格式存在过」的事实
                    reps.append((type.rawValue, Data()))
                case .value(nil):
                    // 空 data 的类型要保留 —— concealed 标记就是这种「只有类型没有内容」的标志位
                    reps.append((type.rawValue, Data()))
                case .value(let data?):
                    total += data.count
                    if total > maxBytes { break }
                    reps.append((type.rawValue, data))
                }
            }
        }
        guard !reps.isEmpty else { return nil }

        let front = frontmostApp()
        return RawSnapshot(
            representations: reps,
            sourceBundleID: front?.bundleID,
            sourceAppName: front?.name,
            windowTitle: nil,   // 需要 Accessibility 权限，M3 再接；拿不到就留空，不阻塞入库
            capturedAt: Date()
        )
    }

    enum ReadOutcome {
        case value(Data?)
        case timedOut
    }

    /// 带超时的单类型读取。
    ///
    /// `data(forType:)` 不可取消，超时后那个线程仍会挂着直到系统超时 —— 这是可接受的代价：
    /// 泄漏一个短命线程，好过让整个捕获循环冻结十几秒。
    static func readWithTimeout(_ item: NSPasteboardItem, _ type: NSPasteboard.PasteboardType) -> ReadOutcome {
        let sem = DispatchSemaphore(value: 0)
        // 用 NSLock 保护，避免超时后后台线程写入与主线程读取竞争
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let d = item.data(forType: type)
            box.set(d)
            sem.signal()
        }
        if sem.wait(timeout: .now() + perTypeTimeout) == .timedOut {
            return .timedOut
        }
        return .value(box.get())
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ d: Data?) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func frontmostApp() -> (bundleID: String?, name: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.bundleIdentifier, app.localizedName)
    }

    /// 系统空闲秒数（无键鼠输入）。用于自适应降频。
    static func systemIdleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDSystem"),
                                           &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let ns = dict["HIDIdleTime"] as? NSNumber else { return 0 }

        return TimeInterval(ns.int64Value) / 1_000_000_000
    }
}
