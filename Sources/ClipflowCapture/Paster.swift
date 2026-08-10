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

    /// 把 representation 写回剪贴板并粘贴到前台 App。
    ///
    /// - Parameters:
    ///   - restoreAfter: 粘贴后是否恢复原剪贴板内容（默认恢复，避免污染用户剪贴板）
    public func paste(representations: [(uti: String, data: Data)],
                      restoreAfter: Bool = true) throws {
        guard !representations.isEmpty else { throw Failure.nothingToPaste }
        guard Self.hasAccessibilityPermission else { throw Failure.noAccessibilityPermission }
        if Self.isSecureInputEnabled() { throw Failure.secureInputEnabled(byProcess: nil) }

        let pb = NSPasteboard.general

        // ① 备份当前剪贴板（原样保存全部 representation，恢复时才能无损）
        let backup: [[String: Data]] = restoreAfter ? Self.snapshotForRestore(pb) : []

        // ② 写入目标内容
        writeToPasteboard(representations)

        // ③ 告诉 watcher 忽略这次由我们自己造成的变更，否则会捕获到自己粘贴的内容形成回声
        watcher?.suppressNextChange()

        // ④ 合成 Cmd+V
        Self.sendCommandV()

        // ⑤ 延迟恢复原剪贴板。
        //    必须延迟：目标 App 是异步读取剪贴板的，立刻恢复会让它读到旧内容。
        if restoreAfter, !backup.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak watcher] in
                let pb = NSPasteboard.general
                pb.clearContents()
                for itemDict in backup {
                    let item = NSPasteboardItem()
                    for (uti, data) in itemDict {
                        item.setData(data, forType: NSPasteboard.PasteboardType(uti))
                    }
                    pb.writeObjects([item])
                }
                watcher?.suppressNextChange()
            }
        }
    }

    /// 只放进剪贴板，不合成按键。无权限时的降级路径。
    public func copyOnly(representations: [(uti: String, data: Data)]) {
        writeToPasteboard(representations)
        watcher?.suppressNextChange()
    }

    private func writeToPasteboard(_ representations: [(uti: String, data: Data)]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        for (uti, data) in representations where !data.isEmpty {
            item.setData(data, forType: NSPasteboard.PasteboardType(uti))
        }
        pb.writeObjects([item])
    }

    static func snapshotForRestore(_ pb: NSPasteboard) -> [[String: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [String: Data] = [:]
            for t in item.types where TypePolicy.shouldRead(t.rawValue) {
                if let d = item.data(forType: t) { dict[t.rawValue] = d }
            }
            return dict
        }
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
