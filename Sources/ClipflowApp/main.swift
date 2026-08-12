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
    fileprivate var hotKey: HotKey?
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
    private var ocrWorker: OCRWorker?
    /// 可观测：上次粘贴等待前台就绪花了多久
    private(set) var lastPasteWaitMs: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻，不进 Dock
        NSApp.setActivationPolicy(.accessory)

        do {
            // 演示/测试用：指定数据目录，避免拿真实历史去截图或跑验证
            let paths = ProcessInfo.processInfo.environment["CLIPFLOW_DATA_DIR"]
                .map { StoragePaths(root: URL(fileURLWithPath: $0)) } ?? .defaultLocation()
            store = try ClipflowStore(paths: paths)
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
        autoCheckUpdatesIfEnabled()
        startOCR()
        backfillJSONKindOnce()

        // 演示模式：启动即在屏幕中央打开面板，供文档截图
        if ProcessInfo.processInfo.environment["CLIPFLOW_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.model.reload()
                if let screen = NSScreen.main {
                    let f = self.panel.frame
                    self.panel.setFrameOrigin(NSPoint(
                        x: screen.frame.midX - f.width / 2,
                        y: screen.frame.midY - f.height / 2))
                }
                self.panel.fadeIn()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        // 用 squareLength + 固定 18×18 模板图，与系统图标对齐。
        //
        // 默认直接塞 SF Symbol 会得到 16×18 —— 比系统自带图标（高 11~14）高出一截，
        // 在菜单栏里显得又大又挤、跟邻居对不齐。这里把字形按比例缩到 15pt 高
        // 再居中画进 18×18 画布，宽高就固定了，换任何符号都不会变形。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon(symbol: "doc.on.clipboard")

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

    /// 把 SF Symbol 规整成菜单栏标准尺寸的模板图。
    static func menuBarIcon(symbol: String, canvas: CGFloat = 18, glyphHeight: CGFloat = 15) -> NSImage? {
        guard let src = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clipflow") else {
            return nil
        }
        let scale = glyphHeight / max(src.size.height, 1)
        let w = src.size.width * scale, h = src.size.height * scale

        let out = NSImage(size: NSSize(width: canvas, height: canvas))
        out.lockFocus()
        src.draw(in: NSRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.isTemplate = true      // 跟随菜单栏明暗自动反色
        return out
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let count = (try? store.count()) ?? 0
        let header = NSMenuItem(title: "Clipflow · 已记录 \(count) 条", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // 显示**实际生效**的组合；一个都注册不上时明确说出来，不装作正常
        let title = activeCombo.map { "打开剪贴板面板（\($0.display)）" }
            ?? "打开剪贴板面板（快捷键未生效）"
        let open = NSMenuItem(title: title, action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        if activeCombo == nil {
            open.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                 accessibilityDescription: nil)
        }
        menu.addItem(open)

        menu.addItem(.separator())

        // 权限状态**始终显示**，不是只在缺失时才出现。
        // 只在缺失时显示的话，用户授权后看到条目消失，没法确认"到底成没成"。
        // 状态用 SF Symbol 表达，不用 emoji —— 原生应用不该出现表情符号
        let granted = Paster.hasAccessibilityPermission
        let perm = NSMenuItem(
            title: granted ? "自动粘贴已就绪" : "未授权 — 点此授予辅助功能权限",
            action: granted ? nil : #selector(requestPermission), keyEquivalent: "")
        perm.target = self
        perm.isEnabled = !granted
        perm.image = NSImage(systemSymbolName: granted ? "checkmark.circle" : "exclamationmark.triangle",
                             accessibilityDescription: nil)
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
        let log = NSMenuItem(title: "查看粘贴日志…", action: #selector(openPasteLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let donate = NSMenuItem(title: "赞赏支持…", action: #selector(openDonate), keyEquivalent: "")
        donate.target = self
        donate.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        menu.addItem(donate)

        let update = NSMenuItem(title: updateMenuTitle, action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        if pendingUpdateVersion != nil {
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        }
        menu.addItem(update)

        let about = NSMenuItem(title: "关于 Clipflow", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
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

    /// JSON / SQL 类型是后加的，之前攒下的这类条目都被标成了文本/富文本/代码。
    /// 回填一次让老条目也归位。做完打标记，不重复跑；**加新类型时把 key 升个版本**
    /// 就能让所有人再跑一轮。
    private func backfillJSONKindOnce() {
        let key = "com.tomeageer.clipflow.contentBackfill.v3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let store = self.store else { return }
        Task.detached(priority: .utility) {
            let n = (try? store.reclassifyJSON()) ?? 0
            UserDefaults.standard.set(true, forKey: key)
            if n > 0 {
                await MainActor.run { AppDelegate.current?.model.reload() }
                print("类型回填：\(n) 条老条目改标为 JSON / SQL / 命令")
            }
        }
    }

    // MARK: 面板

    private func setupPanel() {
        let saved = ClipflowSettings.load()
        panel = ClipPanel(contentRect: NSRect(x: 0, y: 0,
                                              width: saved.panelWidth, height: saved.panelHeight))
        panel.onResize = { size in
            var s = ClipflowSettings.load()
            s.panelWidth = Double(size.width)
            s.panelHeight = Double(size.height)
            s.save()
        }
        panel.contentView = PanelHostingView(rootView: ClipListView(model: model))
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        panel.onModifierKey = { [weak self] action in
            self?.model.handleKey(action) ?? false
        }
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        // 设置里改过缩放/尺寸/开发者模式的话，这次唤出就生效
        let s = ClipflowSettings.load()
        model.applySettings(s)
        // 先记住当前前台 App，关闭时原样还回去
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }

        model.query = ""
        model.reload()
        // 尺寸和位置一起算：贴边时缩尺寸而不是翻到另一边。
        // 保存的尺寸是**偏好值**，每次唤出都从它重新起算 —— 上次被贴边缩过不影响这次。
        let anchor = panel.place(preferred: NSSize(width: s.panelWidth, height: s.panelHeight))
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
        PasteLog.write("——— 开始粘贴，目标 App = \(target?.localizedName ?? "未记录") ———")
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
        // 启动时用保存的组合；注册不上就退默认、再不行就走备选。
        // 绝不允许启动完成后处于"没有热键"的状态。
        let saved = HotKeyCombo.load()
        if !applyHotKey(saved, allowFallback: true) {
            notify("全局快捷键注册失败，可能被其它 App 占用。\n请在「设置 → 快捷键」里换一个组合。")
        }
    }

    /// 当前**实际生效**的组合。可能与用户保存的不同（保存的那个注册失败时）。
    /// 菜单与设置页都显示这个，而不是"想要的那个" —— 否则界面在骗人。
    private(set) var activeCombo: HotKeyCombo?

    /// 注册/重注册全局热键。用 Carbon RegisterEventHotKey，不需要辅助功能权限 ——
    /// 唤出面板这件事本来就不该要权限。
    ///
    /// - Parameter allowFallback: 注册失败时是否自动退到默认/备选组合。
    ///   启动路径必须为 true；用户手动改快捷键时为 false（该让他知道这个组合不行）。
    @discardableResult
    func applyHotKey(_ combo: HotKeyCombo, allowFallback: Bool = false) -> Bool {
        if register(combo) { return true }
        guard allowFallback else {
            // 用户选的组合不可用：保持原来那个继续生效，不要让他失去热键
            if let active = activeCombo { _ = register(active) }
            rebuildMenu()
            return false
        }
        for candidate in HotKeyCombo.fallbacks where candidate != combo {
            if register(candidate) { return true }
        }
        activeCombo = nil
        rebuildMenu()
        return false
    }

    private func register(_ combo: HotKeyCombo) -> Bool {
        hotKey?.unregister()
        hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
        guard hotKey != nil else { activeCombo = nil; return false }
        activeCombo = combo
        combo.save()
        rebuildMenu()
        return true
    }

    /// 恢复默认快捷键
    @discardableResult
    static func resetHotKeyToDefault() -> Bool {
        HotKeyCombo.reset()
        return current?.applyHotKey(.default, allowFallback: true) ?? false
    }

    static func currentActiveCombo() -> HotKeyCombo? { current?.activeCombo }

    static func applyHotKeyGlobally(_ combo: HotKeyCombo) -> Bool {
        current?.applyHotKey(combo) ?? false
    }

    /// 录制新快捷键期间必须先注销全局热键。
    ///
    /// Carbon 的 RegisterEventHotKey 在**系统层**就把按键吃掉了，
    /// 轮不到 App 内的 local monitor —— 用户想录 ⌘⇧V，结果面板被唤出来了。
    static func suspendHotKey() {
        current?.hotKey?.unregister()
        current?.hotKey = nil
    }

    /// 录制结束（成功或取消）后恢复。传 nil 表示恢复成已保存的那个。
    @discardableResult
    static func resumeHotKey(_ combo: HotKeyCombo? = nil) -> Bool {
        // 恢复路径允许回退：宁可换个组合，也不能停在没有热键的状态
        current?.applyHotKey(combo ?? HotKeyCombo.load(), allowFallback: true) ?? false
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

    @objc private func openPasteLog() {
        let url = PasteLog.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "（还没有粘贴记录）".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(store: store) }
        settingsWC?.show()
    }

    /// 后台检查到的新版本号；有值时菜单会直接提示
    private var pendingUpdateVersion: String?

    private var updateMenuTitle: String {
        if let v = pendingUpdateVersion { return "有新版本 \(v) — 点此下载" }
        return "检查更新…"
    }

    @objc private func openDonate() { Updater.openDonate() }

    @objc private func checkUpdates() {
        if pendingUpdateVersion != nil { Updater.openReleasePage(); return }
        Task { @MainActor in
            do {
                let r = try await Updater.check()
                if r.hasUpdate {
                    pendingUpdateVersion = r.latest
                    rebuildMenu()
                    let a = NSAlert()
                    a.messageText = "有新版本 \(r.latest)"
                    a.informativeText = "当前版本 \(r.current)。前往下载？"
                    a.addButton(withTitle: "前往下载")
                    a.addButton(withTitle: "稍后")
                    if a.runModal() == .alertFirstButtonReturn { Updater.openReleasePage() }
                } else {
                    let a = NSAlert()
                    a.messageText = "已是最新版本"
                    a.informativeText = "当前版本 \(r.current)。"
                    a.runModal()
                }
            } catch {
                let a = NSAlert()
                a.messageText = "检查更新失败"
                a.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                a.runModal()
            }
        }
    }

    /// 启动后静默检查一次（可在设置里关）。失败完全静默 —— 更新检查失败不该打扰用户。
    private func autoCheckUpdatesIfEnabled() {
        guard ClipflowSettings.load().autoCheckUpdates else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let r = try? await Updater.check(), r.hasUpdate else { return }
            pendingUpdateVersion = r.latest
            rebuildMenu()
        }
    }

    @objc private func openAbout() {
        if settingsWC == nil { settingsWC = SettingsWindowController(store: store) }
        settingsWC?.show(tab: 3)
    }

    /// 启动 OCR 后台工作者，并做一次自检。
    ///
    /// 自检是必要的：accurate 超限时**静默返回空数组、不报错**，
    /// 是"代码在跑但什么都没索引"的典型形态。识别不出就写进粘贴日志，能被发现。
    private func startOCR() {
        guard ClipflowSettings.load().enableOCR else { return }
        let w = OCRWorker(store: store)
        ocrWorker = w
        Task.detached(priority: .utility) {
            let check = await w.runSelfCheck()
            PasteLog.write("OCR 自检: \(check.passed ? "通过" : "失败") — \(check.detail)")
            await w.start()
        }
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
        if let w = ocrWorker { Task { await w.stop() } }
        try? store?.optimize()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
