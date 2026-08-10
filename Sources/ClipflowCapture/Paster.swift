import AppKit
import Carbon.HIToolbox
import ClipflowCore

/// 粘贴引擎：把内容写回剪贴板并向前台 App 合成 Cmd+V。
///
/// 顺序错了就失败，每一步都有明确理由。
public final class Paster: @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case noAccessibilityPermission
        case secureInputEnabled(byProcess: String?)
        case nothingToPaste

        public var description: String {
            switch self {
            case .noAccessibilityPermission:
                return "需要「辅助功能」权限才能自动粘贴"
            case .secureInputEnabled(let p):
                return "系统处于安全输入模式\(p.map { "（\($0)）" } ?? "")，合成按键会被吞掉"
            case .nothingToPaste:
                return "没有可粘贴的内容"
            }
        }
    }

    private let watcher: PasteboardWatcher?

    public init(watcher: PasteboardWatcher? = nil) {
        self.watcher = watcher
    }

    /// 是否已获得辅助功能权限（合成按键必需）
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统授权引导（只在用户主动触发时调用，不要在启动时骚扰）
    public static func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt 是全局 var，Swift 6 严格并发下不能直接引用；
        // 它的实际值是固定字符串，直接用字面量等价且线程安全。
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// ⚠️ Secure Input：密码框聚焦时系统会吞掉所有合成事件。
    /// 不检测的话表现为「点了没反应」，用户完全无从判断，必须明确报出来。
    public static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// 只写剪贴板，立即返回。与"等前台恢复再合成按键"拆开，是为了让写入不被任何等待挡住。
    ///
    /// **不备份、不恢复原剪贴板**：从历史里选一条粘贴，语义上就等于"重新复制了它"，
    /// 之后再按 ⌘V 理应还是这条。恢复旧内容会让用户困惑，而且备份需要读全部
    /// representation —— 那是可能阻塞的操作，白白挡在粘贴路径上。
    public func stage(representations: [(uti: String, data: Data, itemIndex: Int)]) throws {
        guard !representations.isEmpty else { throw Failure.nothingToPaste }
        writeToPasteboard(representations)
        watcher?.suppressNextChange()
    }

    /// 等目标 App 真正回到前台，然后合成 ⌘V。
    ///
    /// ⚠️ **必须轮询，不能固定 sleep。**
    /// 固定延迟要么太短（按键打到还没切回来的 App 上，粘贴丢失），
    /// 要么太长（用户感到明显的延迟）。轮询取两者之长：通常 10~30ms 就绪。
    ///
    /// - Parameter target: 期望回到前台的 App；nil 表示不等待
    /// - Returns: 实际等待毫秒数（用于观测）
    @discardableResult
    public func pasteNow(waitingFor target: NSRunningApplication?,
                         timeout: TimeInterval = 0.25) throws -> Double {
        guard Self.hasAccessibilityPermission else { throw Failure.noAccessibilityPermission }
        if Self.isSecureInputEnabled() { throw Failure.secureInputEnabled(byProcess: nil) }

        let t0 = CFAbsoluteTimeGetCurrent()
        if let target {
            let deadline = t0 + timeout
            while CFAbsoluteTimeGetCurrent() < deadline {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    break
                }
                // 2ms 一次。比起固定 90ms，这里最坏也就多花几毫秒。
                usleep(2000)
            }
        }
        Self.sendCommandV()
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// 一步到位（保留给不关心时序的调用方）
    public func paste(representations: [(uti: String, data: Data, itemIndex: Int)]) throws {
        try stage(representations: representations)
        try pasteNow(waitingFor: nil)
    }

    /// 只放进剪贴板，不合成按键。无权限时的降级路径。
    public func copyOnly(representations: [(uti: String, data: Data, itemIndex: Int)]) {
        writeToPasteboard(representations)
        watcher?.suppressNextChange()
    }

    /// 写回剪贴板。**必须还原原来的多 item 结构**。
    ///
    /// 复制多个文件时剪贴板上是多个 NSPasteboardItem，每个挂一个 public.file-url。
    /// 如果塞进同一个 item 反复 setData，同一 UTI 后者覆盖前者 —— 三个文件只剩一个。
    /// 实测：原生写法 `readObjects(forClasses:[NSURL])` 得到 2 个，拍平写法只得到 1 个。
    private func writeToPasteboard(_ representations: [(uti: String, data: Data, itemIndex: Int)]) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // 按原来的 item 分组还原
        let grouped = Dictionary(grouping: representations.filter { !$0.data.isEmpty },
                                 by: { $0.itemIndex })
        let items: [NSPasteboardItem] = grouped.keys.sorted().compactMap { idx in
            guard let reps = grouped[idx], !reps.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for r in reps {
                item.setData(r.data, forType: NSPasteboard.PasteboardType(r.uti))
            }
            return item
        }
        guard !items.isEmpty else { return }
        pb.writeObjects(items)
    }

    /// 合成 Cmd+V。用 CGEvent 而非 AppleScript —— 更快且不依赖自动化权限。
    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // 屏蔽本地键盘状态，避免用户此刻按住的修饰键（如 Shift）污染合成事件
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)

        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
