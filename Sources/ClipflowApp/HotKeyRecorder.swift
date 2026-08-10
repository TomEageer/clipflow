import AppKit
import SwiftUI
import Carbon.HIToolbox
import ClipflowCore

/// 一个热键的可持久化表示。
struct HotKeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon 修饰键掩码（cmdKey / shiftKey / optionKey / controlKey）
    var carbonModifiers: UInt32

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V),
                                       carbonModifiers: UInt32(cmdKey | shiftKey))

    /// 从 AppKit 事件转换
    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        // 必须带至少一个修饰键，否则会把普通打字劫走
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    /// 人类可读，如 "⌘⇧V"
    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(keyCode)
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "空格", UInt32(kVK_Return): "⏎", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Grave): "`",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return map[code] ?? "键\(code)"
    }

    // MARK: 持久化

    private static let key = "com.tomeageer.clipflow.hotkey"

    static func load() -> HotKeyCombo {
        guard let d = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(HotKeyCombo.self, from: d) else { return .default }
        return c
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: Self.key)
    }
}

// MARK: - 录制控件

/// 点一下开始录制，按下组合键即录入。
struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var combo: HotKeyCombo
    var onChange: (HotKeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.combo = combo
        b.onChange = { c in
            combo = c
            onChange(c)
        }
        return b
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.combo = combo
        nsView.refreshTitle()
    }
}

final class RecorderButton: NSButton {
    var combo: HotKeyCombo = .default
    var onChange: ((HotKeyCombo) -> Void)?
    private var recording = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshTitle() {
        title = recording ? "按下组合键…（esc 取消）" : combo.display
    }

    @objc private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        refreshTitle()
        // local monitor 才能在本 App 窗口里拦到按键；录制期间要吃掉所有 keyDown
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            if let c = HotKeyCombo(event: event) {
                self.combo = c
                self.onChange?(c)
                self.stop()
            }
            // 没带修饰键的按键不接受，但也不放行，避免误触发别的控件
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        refreshTitle()
    }
}
