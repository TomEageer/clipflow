import AppKit
import SwiftUI
import Carbon.HIToolbox
import ClipflowCore
import ClipflowCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: ClipPanel!
    private var model: PanelModel!
    private var hotKey: HotKey?
    private var watcher: PasteboardWatcher!
    private var store: ClipflowStore!
    private var captureTask: Task<Void, Never>?
    private var capturedCount = 0
    /// 唤出面板前记住是谁在前台，关闭时还回去。
    /// 不还的话，关掉面板后前台是 Clipflow 自己 —— 用户看到原窗口标题栏变灰，
    /// 而且下一次 ⌘V 会打到空处。这是"生硬"感最主要的来源之一。
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不进 Dock
        NSApp.setActivationPolicy(.accessory)

        do {
            store = try ClipflowStore(paths: .defaultLocation())
        } catch {
            let a = NSAlert()
            a.messageText = "无法打开数据库"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        watcher = PasteboardWatcher()
        let paster = Paster(watcher: watcher)
        model = PanelModel(store: store, paster: paster)
        model.onClose = { [weak self] in self?.hidePanel() }
        model.onError = { [weak self] msg in self?.notify(msg) }

        AppDelegate.current = self
        setupStatusItem()
        setupPanel()
        setupHotKey()
        startCapture()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Clipflow")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let count = (try? store.count()) ?? 0
        menu.addItem(withTitle: "Clipflow · 已记录 \(count) 条", action: nil, keyEquivalent: "")
        menu.items.first?.isEnabled = false
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开剪贴板面板", action: #selector(togglePanel), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)

        if !Paster.hasAccessibilityPermission {
            menu.addItem(.separator())
            let perm = NSMenuItem(title: "⚠️ 授予辅助功能权限（用于自动粘贴）",
                                  action: #selector(requestPermission), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }

        menu.addItem(.separator())
        let stats = NSMenuItem(title: "存储占用…", action: #selector(showStats), keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)

        let quit = NSMenuItem(title: "退出 Clipflow", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: 面板

    private func setupPanel() {
        panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440))
        panel.contentView = NSHostingView(rootView: ClipListView(model: model))
        panel.onDismiss = { [weak self] in self?.hidePanel() }
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        // 先记住当前前台 App，关闭时原样还回去
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }

        model.query = ""
        model.reload()
        panel.positionAtCursor()
        panel.fadeIn()
        // nonactivating panel 不抢前台，但要激活自己才能收键盘输入
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.fadeOut { [weak self] in
            guard let self else { return }
            // 焦点还给原来那个 App。放在淡出完成之后，避免动画期间来回抢。
            if let prev = self.previousApp, !prev.isTerminated {
                prev.activate()
            }
            self.previousApp = nil
        }
    }

    // MARK: 热键

    private func setupHotKey() {
        // ⌘⇧V —— 用 Carbon RegisterEventHotKey，不需要辅助功能权限
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V),
                        modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
        if hotKey == nil {
            notify("全局热键 ⌘⇧V 注册失败，可能已被其它 App 占用")
        }
    }

    // MARK: 捕获

    private func startCapture() {
        let ingest = IngestService(store: store)
        let w = watcher!
        captureTask = Task.detached {
            for await snap in w.start() {
                guard ((try? ingest.ingest(snap)) ?? nil) != nil else { continue }
                await AppDelegate.notifyCaptured()
            }
        }
    }

    // MARK: 杂项

    @objc private func requestPermission() {
        Paster.requestAccessibilityPermission()
    }

    @objc private func showStats() {
        guard let s = try? store.stats() else { return }
        let f = ByteCountFormatter()
        let a = NSAlert()
        a.messageText = "Clipflow 存储占用"
        a.informativeText = """
        条目          \(s.items)
        内容库        \(f.string(fromByteCount: Int64(s.contentDBBytes)))
        索引库        \(f.string(fromByteCount: Int64(s.indexDBBytes)))
        附件          \(s.blobCount) 个 / \(f.string(fromByteCount: Int64(s.blobBytes)))
        合计          \(f.string(fromByteCount: Int64(s.totalBytes)))

        目录 \(store.paths.root.path)
        """
        a.runModal()
    }

    private func notify(_ message: String) {
        let a = NSAlert()
        a.messageText = "Clipflow"
        a.informativeText = message
        a.alertStyle = .informational
        a.runModal()
    }

    /// 捕获到新内容时刷新 UI。用静态方法 + 弱引用，避免把 detached task 与 self 的
    /// 隔离域纠缠在一起（Swift 6 会判定为数据竞争风险）。
    private static weak var current: AppDelegate?

    static func notifyCaptured() async {
        await MainActor.run {
            guard let d = current else { return }
            d.capturedCount += 1
            d.rebuildMenu()
            if d.panel.isVisible { d.model.reload() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        watcher?.stop()
        captureTask?.cancel()
        try? store?.optimize()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
