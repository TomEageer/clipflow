import AppKit
import Carbon.HIToolbox

/// 全局热键。
///
/// 用 Carbon `RegisterEventHotKey` 而不是 `NSEvent.addGlobalMonitorForEvents`：
/// 后者需要「辅助功能」权限，而热键本身不该要权限 —— 用户还没授权时也得能唤出面板。
/// （合成 Cmd+V 才需要辅助功能，那是另一件事。）
@MainActor
final class HotKey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: 虚拟键码，如 `kVK_ANSI_V`
    ///   - modifiers: Carbon 修饰键掩码，如 `cmdKey | shiftKey`
    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = Self.nextID
        Self.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            // Carbon 回调在主线程触发，但编译器看不出来，显式跳回 MainActor
            let fired = hkID.id
            DispatchQueue.main.async { HotKey.instances[fired]?.onFire() }
            return noErr
        }, 1, &eventType, nil, &handler)

        guard installStatus == noErr else { return nil }

        let hkID = EventHotKeyID(signature: OSType(0x434C4650 /* CLFP */), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }

        Self.instances[id] = self
    }

    /// 显式注销。App 生命周期内热键常驻，不依赖 deinit（Swift 6 下 deinit 访问
    /// 非 Sendable 的 Carbon 句柄会报并发错误，显式方法更清晰也更可控）。
    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        Self.instances[id] = nil
    }
}
