import AppKit
import SwiftUI
import Carbon.HIToolbox
import ClipflowCore
import ClipflowCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

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
    private var paster: Paster!
    private var settingsWC: SettingsWindowController?
    private var settings = ClipflowSettings.load()
    private var cleanupTimer: Timer?
    /// 可观测：上次粘贴等待前台就绪花了多久
    private(set) var lastPasteWaitMs: Double = 0

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
        paster = Paster(watcher: watcher)
        model = PanelModel(store: store, paster: paster)
        model.onClose = { [weak self] in self?.hidePanel() }
        model.onPaste = { [weak self] in self?.pasteToPreviousApp() }
        model.onError = { [weak self] msg in self?.notify(msg) }

        AppDelegate.current = self
        setupStatusItem()
        setupPanel()
        setupHotKey()
        startCapture()
        startCleanupSchedule()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Clipflow")
        statusItem.button?.image?.isTemplate = true

        // ⚠️ 菜单必须**每次打开时重建**。
        // 之前只在启动和捕获到新内容时重建，用户去系统设置授完权回来，
        // 菜单还显示「未授权」—— 看着像 App 坏了。
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        // 系统在辅助功能授权变化时会广播这个通知，收到就立刻刷新
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
    }

    /// NSMenuDelegate：菜单即将展开时重建，保证状态永远是当下的
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func accessibilityChanged() {
        // 通知到达时系统状态可能还没落定，延迟一拍再读
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let count = (try? store.count()) ?? 0
        let header = NSMenuItem(title: "Clipflow · 已记录 \(count) 条", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let combo = HotKeyCombo.load()
        let open = NSMenuItem(title: "打开剪贴板面板（\(combo.display)）",
                              action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        // 权限状态**始终显示**，不是只在缺失时才出现。
        // 只在缺失时显示的话，用户授权后看到条目消失，没法确认"到底成没成"。
        let granted = Paster.hasAccessibilityPermission
        let perm = NSMenuItem(
            title: granted ? "✅ 自动粘贴已就绪" : "⚠️ 未授权 —— 点此授予辅助功能权限",
            action: granted ? nil : #selector(requestPermission), keyEquivalent: "")
        perm.target = self
        perm.isEnabled = !granted
        menu.addItem(perm)

        if !granted {
            let hint = NSMenuItem(title: "    （未授权也能用：内容会放进剪贴板，手动 ⌘V）",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            let reopen = NSMenuItem(title: "    授权后仍显示未授权？点此重开系统设置",
                                    action: #selector(openAccessibilitySettings), keyEquivalent: "")
            reopen.target = self
            menu.addItem(reopen)
        }

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let quit = NSMenuItem(title: "退出 Clipflow", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// 用户去系统设置操作期间轮询，回来就能看到状态已更新。
    /// 只靠系统通知不够可靠 —— 实测有时不广播或延迟很久。
    private var permissionPollTimer: Timer?
    private var permissionPollTicks = 0

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTicks = 0
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollPermissionOnce() }
        }
    }

    private func pollPermissionOnce() {
        permissionPollTicks += 1
        rebuildMenu()
        if Paster.hasAccessibilityPermission || permissionPollTicks > 90 {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 面板

    private func setupPanel() {
        panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440))
        panel.contentView = NSHostingView(rootView: ClipListView(model: model))
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        panel.onModifierKey = { [weak self] action in
            self?.model.handleKey(action) ?? false
        }
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
        let anchor = panel.positionAtCursor()
        // 面板开在鼠标左侧时，把列表挪到靠鼠标的那一边
        model.mirrored = anchor.mirrorsHorizontally
        panel.fadeIn()
        // nonactivating panel 不抢前台，但要激活自己才能收键盘输入
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关面板 → 切回原 App → 轮询等它真正到前台 → 合成 ⌘V。
    ///
    /// 内容此时已经在剪贴板里了（PanelModel.confirm 第一步就写了），
    /// 所以哪怕这里任何一步失败，用户手动 ⌘V 也拿得到。
    private func pasteToPreviousApp() {
        let target = previousApp
        // 立刻收起面板。orderOut 而不是等淡出动画 —— 粘贴路径上不留任何等待。
        panel.orderOut(nil)
        target?.activate()
        previousApp = nil

        // 轮询放到后台，别阻塞主线程（合成按键本身不需要在主线程）
        guard let paster = self.paster else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                let waited = try paster.pasteNow(waitingFor: target)
                Task { @MainActor in self?.lastPasteWaitMs = waited }
            } catch {
                Task { @MainActor in self?.model.reportPasteFailure("\(error)") }
            }
        }
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
        applyHotKey(HotKeyCombo.load())
    }

    /// 注册/重注册全局热键。用 Carbon RegisterEventHotKey，不需要辅助功能权限 ——
    /// 唤出面板这件事本来就不该要权限。
    @discardableResult
    func applyHotKey(_ combo: HotKeyCombo) -> Bool {
        hotKey?.unregister()
        hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
        let ok = hotKey != nil
        if ok { combo.save() }
        rebuildMenu()
        return ok
    }

    static func applyHotKeyGlobally(_ combo: HotKeyCombo) -> Bool {
        current?.applyHotKey(combo) ?? false
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
        startPermissionPolling()
    }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(store: store) }
        settingsWC?.show()
    }

    /// 定期按设置清理。启动 30s 后跑一次，之后每小时一次。
    /// 不在启动瞬间跑 —— 那会和"启动时捕获剪贴板"抢资源，用户还什么都没看到就先卡一下。
    private func startCleanupSchedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.runCleanup()
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.runCleanup() }
        }
    }

    private func runCleanup() {
        settings = ClipflowSettings.load()
        let store = self.store!
        let s = settings
        DispatchQueue.global(qos: .utility).async {
            _ = try? store.cleanup(settings: s)
            _ = try? store.vacuumBlobs()
            Task { @MainActor [weak self] in self?.rebuildMenu() }
        }
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
