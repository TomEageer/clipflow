import AppKit
import SwiftUI
import ClipflowCore

/// 鼠标旁弹出的面板。
final class ClipPanel: NSPanel {

    /// 点击面板外部时关闭。剪贴板面板是"用完即走"的，只能按 Esc 关很生硬。
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?
    var onDismiss: (() -> Void)?
    /// 带修饰键的快捷键（⌘1~9 / ⌘P / ⌘⌫）不会经过 field editor 的命令选择器，
    /// 得在面板层面用 local monitor 拦。
    var onModifierKey: ((KeyAction) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        // 可自由拉伸，但给下限 —— 太小的话列表和预览都失去意义
        minSize = NSSize(width: 520, height: 320)
        maxSize = NSSize(width: 1600, height: 1200)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        animationBehavior = .none          // 自己控制淡入淡出，系统动画对浮窗太慢
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 面板相对鼠标的展开方向。
    ///
    /// 只做**左右镜像**，不做上下反转 —— 列表倒序违反阅读直觉，试过，反人类。
    enum Anchor {
        case right   // 面板开在鼠标右侧：列表贴左边，本来就离鼠标近
        case left    // 面板开在鼠标左侧：列表要换到右边，才靠近鼠标

        /// 面板在鼠标左侧时，内部左右布局镜像：可点击的列表挪到靠鼠标那一边
        var mirrorsHorizontally: Bool { self == .left }
    }

    private(set) var anchor: Anchor = .right

    /// 摆到鼠标旁：位置、尺寸、展开方向一次算完。
    ///
    /// **跟随鼠标的目的是让鼠标少动。**
    ///
    /// 面板默认开在鼠标右侧，列表在左半边 —— 紧挨鼠标。
    /// 到了屏幕右边缘只能开在左侧，此时鼠标在面板的**右**边，
    /// 而列表还在最左边，等于隔着整个预览面板，跟随就白做了 ——
    /// 所以这时把列表和预览左右对调。只镜像左右，不做上下反转（列表倒序违反阅读直觉）。
    ///
    /// 但面板能被拉到 1000pt 以上，"右边放不下就翻过去"会让鼠标一进屏幕右半区就触发镜像，
    /// 每次唤出布局都可能不一样。所以贴边时**优先缩尺寸**，缩不住了才翻 ——
    /// 判据见 `PanelPlacement`，那边有测试盯着边界。
    @discardableResult
    func place(preferred: NSSize) -> Anchor {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let r = PanelPlacement.place(mouse: mouse, preferred: preferred,
                                     minSize: minSize, visible: visible)
        isPlacing = true
        setFrame(r.frame, display: false)
        isPlacing = false

        anchor = r.mirrored ? .left : .right
        return anchor
    }

    /// 记住用户拉过的尺寸。下次唤出保持一致，不然每次都要重拉一遍。
    var onResize: ((NSSize) -> Void)?

    /// ⚠️ 程序化摆放期间**绝不能回存尺寸**。
    /// 贴边自适应缩小是"这一次显示"的决定，存下来的话面板会一次比一次小，
    /// 用户辛辛苦苦拉出来的尺寸就这么悄悄丢了。
    private var isPlacing = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let changed = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if changed, isVisible, !isPlacing { onResize?(frameRect.size) }
    }

    /// 淡入。130ms —— 快到不觉得在等，又不会"啪"地跳出来。
    func fadeIn() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        startOutsideClickMonitor()
        startLocalKeyMonitor()
    }

    /// 淡出。比淡入更快 —— 关闭要干脆，拖泥带水最影响手感。
    func fadeOut(completion: (() -> Void)? = nil) {
        stopOutsideClickMonitor()
        stopLocalKeyMonitor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        }
    }

    private func startLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isKeyWindow || self.isVisible else { return event }
            guard event.modifierFlags.contains(.command) else { return event }

            var action: KeyAction?
            if event.keyCode == 51 { action = .delete }               // ⌘⌫
            else if event.keyCode == 36 { action = .pasteTransformed } // ⌘⏎
            else if let c = event.charactersIgnoringModifiers?.lowercased().first {
                if c.isNumber, c != "0" { action = .pick(Int(String(c))! - 1) }
                else if c == "p" { action = .pin }
                else if c == "t" { action = .transform }
                else if c == "r" { action = .rename }
            }
            if let action, self.onModifierKey?(action) == true { return nil }
            return event
        }
    }

    private func stopLocalKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.onDismiss?()
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    /// 面板被 orderOut（粘贴路径）时也要摘掉监听
    override func orderOut(_ sender: Any?) {
        stopOutsideClickMonitor()
        stopLocalKeyMonitor()
        super.orderOut(sender)
    }
}

// MARK: - 面板内容

struct ClipListView: View {
    @ObservedObject var model: PanelModel

    private var t: Theme { Theme(scale: model.uiScale) }

    /// 面板开在鼠标左侧时为 true：列表与预览左右对调，让列表贴着鼠标。
    private var mirrored: Bool { model.mirrored }

    /// 拖动开始时的列表宽度。DragGesture 的 translation 是**从按下那刻起的累计位移**，
    /// 不是每帧增量，所以必须记住基准值再加，否则会指数级跑飞。
    @State private var dragBase: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let listW = model.listWidth(total: total, theme: t)
            let previewW = max(0, total - listW - t.splitterWidth)

            HStack(spacing: 0) {
                if mirrored {
                    PreviewPane(model: model, theme: t).frame(width: previewW)
                    splitter(total: total, listW: listW)
                    listColumn.frame(width: listW)
                } else {
                    listColumn.frame(width: listW)
                    splitter(total: total, listW: listW)
                    PreviewPane(model: model, theme: t).frame(width: previewW)
                }
            }
            .frame(width: total, height: geo.size.height)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }

    /// 可拖动的分隔条。
    ///
    /// 视觉上仍是 1pt 的细线，但**命中区要宽出去**（7pt）——
    /// 1pt 的拖拽热区实际上抓不住，鼠标会一直从旁边滑过去。
    private func splitter(total: CGFloat, listW: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.04))
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
            SplitterHandle(
                onDrag: { dx in
                    let base = dragBase ?? listW
                    if dragBase == nil { dragBase = base }
                    // 镜像时列表在右半边，往右拖是把列表压窄，符号相反
                    model.setListWidth(base + (mirrored ? -dx : dx), total: total, theme: t)
                },
                onEnd: {
                    dragBase = nil
                    model.persistSplit()   // 松手才写盘，拖动过程中每帧存一次纯属浪费
                })
        }
        .frame(width: t.splitterWidth)
    }

    private var listColumn: some View {
            VStack(spacing: 0) {
                searchBar
                categoryBar
                Divider().opacity(0.5)

                if model.items.isEmpty {
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                            .font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text(model.query.isEmpty
                             ? (model.category == .all ? "还没有记录任何内容"
                                                       : "这个分类下还没有内容")
                             : "没有匹配结果")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                        Spacer()
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                    RowView(item: item, index: idx,
                                            selected: idx == model.selection,
                                            thumbnail: model.thumbnail(for: item),
                                            theme: t)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        // 鼠标划过即选中 —— 划上去没反馈是最直接的"生硬"
                                        .onHover { if $0 { model.select(idx) } }
                                        .onTapGesture { model.select(idx); model.confirm() }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        // 只跟随**键盘**移动滚动。鼠标划过绝不滚 ——
                        // 否则列表会追着鼠标跑（划过→选中→滚动→鼠标下换行→再选中…）。
                        .onChange(of: model.scrollToken) { _, _ in
                            let i = model.selection
                            guard i < model.items.count else { return }
                            proxy.scrollTo(model.items[i].id, anchor: .center)
                        }
                    }
                }
                Spacer(minLength: 0)
                footer
            }
    }

    /// 分类切换。内置分类 + 自定义分组排在一条里。
    ///
    /// **不能用 segmented Picker**：分组数量不固定，分段控件会把每一段压到看不清，
    /// 加到七八个分组时整条就废了。改成可横向滚动的胶囊条 ——
    /// 装不下时两端出现 ◀ ▶ 翻页按钮，装得下就完全不出现，不白占地方。
    private var categoryBar: some View {
        CategoryBar(model: model, theme: t)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    private var searchBar: some View {
        SearchField(text: $model.query, onKey: model.handleKey, fontSize: t.size(14))
            .padding(.horizontal, 12)
            .padding(.top, 10).padding(.bottom, 8)
            // 面板没有标题栏，宿主视图又统一关掉了窗口背景拖拽（见 PanelHostingView），
            // 所以在这一行的背景上显式还回"可以拖动窗口"的能力。
            .background(WindowDragHandle())
    }

    /// 底部快捷键条。
    ///
    /// ⚠️ **必须能随列宽降级。** 固定一行五个提示的话，列被拖窄后
    /// 「粘贴」「变换」会被压成两行，整条 footer 变形（实测）。
    /// `ViewThatFits` 从全量往下退，退到只剩条数为止。
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(allHints)
            footerRow(Array(allHints.prefix(3)))
            footerRow(Array(allHints.prefix(2)))
            footerRow([])
        }
    }

    /// 按重要性排序：越靠前越晚被砍掉
    private var allHints: [(String, String)] {
        var h: [(String, String)] = [("↑↓", "选择"), ("⏎", "粘贴")]
        if model.processedText != nil { h.append(("⌘⏎", "粘处理结果")) }
        if !model.availableTransforms.isEmpty { h.append(("⌘T", "变换")) }
        h.append(("⌘P", model.selectedGroupName ?? "分组"))
        h.append(("⌘R", "命名"))
        h.append(("⌘⌫", "删除"))
        return h
    }

    private func footerRow(_ hints: [(String, String)]) -> some View {
        HStack(spacing: 12) {
            Text("\(model.total) 条")
            Spacer(minLength: 8)
            ForEach(hints, id: \.0) { KeyHint($0.0, $0.1) }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.thinMaterial)
    }
}

private struct KeyHint: View {
    let key: String, label: String
    init(_ k: String, _ l: String) { key = k; label = l }
    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, design: .rounded)).bold()
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08)))
            Text(label)
        }
        // 不许在提示内部折行 —— 折了整条 footer 就变高变形，
        // 该做的是让 ViewThatFits 把整个提示砍掉，不是把它压扁
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: 分隔条手柄

/// 分隔条的拖拽手柄。**必须用 AppKit 视图实现，不能用纯 SwiftUI 的 DragGesture。**
///
/// 面板开着 `isMovableByWindowBackground`（它没有标题栏，拖背景是唯一能挪窗口的方式），
/// 而窗口背景拖拽在 AppKit 层就把鼠标事件截走了，**排在 SwiftUI 手势之前**。
/// 实测：拖分隔条时整个面板跟着鼠标跑了 135pt，分栏比例一点没变。
///
/// `mouseDownCanMoveWindow` 是 AppKit 里唯一的退出开关，SwiftUI 没有对应修饰符 ——
/// 所以这一小块必须落到 NSView 上。光标形状也顺手在这里给了，
/// 用 tracking area 而不是 `.onHover` + `NSCursor.push/pop`：后者要求 push/pop 严格配对，
/// 面板在悬停状态下直接关掉时收不到 exit 回调，光标会卡在左右箭头上下不来。
private struct SplitterHandle: NSViewRepresentable {
    /// 相对按下点的**累计**位移（与 DragGesture.translation 同语义）。
    /// 竖向时已经翻过符号：往下拖 = 正数 = 上面那块变高。
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void
    var vertical = false

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onDrag = onDrag
        v.onEnd = onEnd
        v.vertical = vertical
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) {
        v.onDrag = onDrag
        v.onEnd = onEnd
        v.vertical = vertical
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        var vertical = false
        private var start: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }

        /// ⚠️ 光标形状必须**同时**走 cursor rect 和 mouseEntered/Exited 两条路。
        ///
        /// 只挂 `.cursorUpdate` tracking area 实测不生效：这块 NSView 活在
        /// NSHostingView 里，SwiftUI 自己也装了 tracking area 并会把光标重置回箭头，
        /// 谁最后一个设谁说了算。结果就是"鼠标划过分隔条没有 ↔ 提示，
        /// 用户根本不知道这里能拖"。
        ///
        /// `addCursorRect` 由 AppKit 托管、进出自动配平，是主路径；
        /// enter/exit 里再显式 set 一次兜底。**不用 push/pop** ——
        /// 它要求严格配对，面板在悬停状态下直接关掉时收不到 exit，光标会卡住下不来。
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect],
                owner: self))
            window?.invalidateCursorRects(for: self)
        }

        override func cursorUpdate(with event: NSEvent) {
            (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        }

        override func mouseEntered(with event: NSEvent) {
            (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            start = vertical ? event.locationInWindow.y : event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            // AppKit 的 y 轴朝上，往下拖是变小 —— 翻个号，让"往下 = 上面那块变高"
            let now = vertical ? event.locationInWindow.y : event.locationInWindow.x
            onDrag?(vertical ? (start - now) : (now - start))
        }

        override func mouseUp(with event: NSEvent) {
            onEnd?()
        }
    }
}

// MARK: 预览

private struct PreviewPane: View {
    @ObservedObject var model: PanelModel
    let theme: Theme
    private var t: Theme { theme }
    /// 竖向拖动开始时上面那块的高度。translation 是累计位移，必须记基准值。
    @State private var vDragBase: CGFloat?

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if let appIcon = SourceIcon.icon(forBundleID: item.sourceBundleID) {
                                Image(nsImage: appIcon)
                                    .resizable().frame(width: t.size(13), height: t.size(13))
                            }
                            if item.sensitivity == .sensitive {
                                Label("敏感", systemImage: "lock.fill")
                                    .font(t.font(10)).foregroundStyle(.orange)
                            }
                            Text(item.kind.label)
                            Text("·")
                            Text(item.sourceAppName ?? "未知来源").lineLimit(1)
                            Spacer(minLength: 6)
                            // 动作入口放这里而不是只留快捷键 ——
                            // 变换功能之前只能靠 ⌘T 触发，等于没人知道它存在。
                            groupButton
                        }
                        .font(t.font(10)).foregroundStyle(.secondary)
                        nameRow(item)
                    }
                    .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 8)

                    Divider().opacity(0.4)

                    if let big = model.largePreview(for: item) {
                        imagePane(big, item: item)
                    } else if model.processedText != nil {
                        // 上下两块：原文在上、处理结果在下，中间那条可上下拖动改高度。
                        // 原来是靠一个「格式化 / 原文」开关来回切，看不到两者的对照，
                        // 而变换本身又是点一下直接粘出去 —— 等于粘了才知道结果对不对。
                        GeometryReader { geo in
                            let total = geo.size.height
                            let topH = model.originalHeight(total: total, theme: t)
                            VStack(spacing: 0) {
                                originalPane(item).frame(height: topH)
                                vSplitter(total: total, topH: topH)
                                processedPane(item, showBody: true)
                            }
                            .frame(width: geo.size.width, height: total)
                        }
                    } else if !model.availableTransforms.isEmpty {
                        // 还没选变换：下半区只留标题栏，**变换入口就在它上面** ——
                        // 放到最顶上的话，它和"对下半区做什么"这件事离得太远。
                        VStack(spacing: 0) {
                            originalPane(item)
                            Divider()
                            processedPane(item, showBody: false)
                        }
                    } else {
                        originalPane(item)
                    }

                    Divider().opacity(0.4)
                    Text(model.formatSummary(for: item))
                        .font(t.font(9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
                // 菜单锚在按钮正下方，不再钉在整个面板的右下角 ——
                // 那样点完按钮鼠标要横穿整个面板才够得着。
                // 菜单锚在触发它的按钮附近，不钉在整个面板的角上 ——
                // 那样点完按钮鼠标要横穿整个面板才够得着。
                //
                // 底下垫一层透明的点击接收层：**点空白处要能关掉菜单**，
                // 否则只能靠 Esc 或再点一次按钮，很别扭。
                .overlay {
                    if model.popup != .none {
                        ZStack(alignment: model.popup == .groups ? .topTrailing : .bottomTrailing) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { model.popup = .none }
                            if model.popup == .groups {
                                groupMenu.padding(.top, t.size(30)).padding(.trailing, 8)
                            } else {
                                transformMenu.padding(.bottom, t.size(30)).padding(.trailing, 8)
                            }
                        }
                    }
                }
            } else {
                VStack { Spacer()
                    Text("选中一条查看").font(t.font(11)).foregroundStyle(.tertiary)
                    Spacer() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 三种内容区

    private func imagePane(_ image: NSImage, item: ClipItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                // 图里识别出的文字 —— 搜索能命中它，所以要让用户看得见
                if let ocr = model.ocrText(for: item) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("图中文字", systemImage: "text.viewfinder")
                            .font(t.font(10)).foregroundStyle(.secondary)
                        Text(ocr)
                            .font(t.font(10))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
    }

    /// 上半区：原文。默认只读，点「编辑」才能改，改完可「复原」。
    /// **编辑只影响这一次复制/粘贴，永不写回库。**
    private func originalPane(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(
                title: "原文",
                icon: "doc.plaintext",
                edited: model.isOriginalEdited,
                canEdit: !model.originalTruncated,
                editing: $model.editingOriginal,
                copied: model.copiedFlash == "原文",
                onCopy: { model.copyOriginal() },
                onRevert: { model.revertOriginal() },
                trailing: { EmptyView() })

            paneBody(text: model.originalBinding,
                     editing: model.editingOriginal,
                     mono: item.kind == .code || item.kind == .json)
        }
        .frame(maxHeight: .infinity)
    }

    /// 下半区：处理结果 + 变换入口 + 就地粘贴。同样可编辑、可复原。
    ///
    /// **标题栏常驻**（只要有可用变换），因为「变换」按钮就住在这里 ——
    /// 它要作用的对象就是下半区，放到最顶上离得太远。
    private func processedPane(_ item: ClipItem, showBody: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(
                title: model.activeTransform?.title ?? "处理结果",
                icon: "arrow.turn.down.right",
                edited: model.isProcessedEdited,
                canEdit: !model.processedTruncated,
                editing: $model.editingProcessed,
                copied: model.copiedFlash == "结果",
                showCopy: showBody,
                onCopy: { model.copyProcessed() },
                onRevert: { model.revertProcessed() },
                leading: { transformButton },
                trailing: {
                    if showBody {
                        Button { model.pasteTransformed() } label: {
                            HStack(spacing: 3) {
                                Text("粘贴")
                                Text("⌘⏎").foregroundStyle(.tertiary)
                            }
                            .font(t.font(10))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.primary.opacity(0.08)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("把处理结果粘到刚才那个 App，库里的原始内容不变")
                        Button { model.clearTransform() } label: {
                            Image(systemName: "xmark").font(t.font(9))
                        }
                        .buttonStyle(.plain)
                        .help("收起处理结果")
                    }
                })

            if showBody {
                // 处理结果**一直可编辑**，不设编辑开关：它本来就是派生数据，
                // 改坏了点「复原」重算就行，没有"保护原始内容"的顾虑（原文那边才有）。
                paneBody(text: model.processedBinding, editing: true, mono: true)
            }
        }
        .frame(maxHeight: showBody ? .infinity : nil)
    }

    /// 预览区上下两块之间的拖动条。和左右分栏同一套实现（`SplitterHandle`），
    /// 只是换成竖向 —— 同样必须走 AppKit，SwiftUI 手势会被窗口背景拖拽抢走。
    private func vSplitter(total: CGFloat, topH: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.04))
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            SplitterHandle(
                onDrag: { dy in
                    let base = vDragBase ?? topH
                    if vDragBase == nil { vDragBase = base }
                    model.setOriginalHeight(base + dy, total: total, theme: t)
                },
                onEnd: {
                    vDragBase = nil
                    model.persistPreviewSplit()
                },
                vertical: true)
        }
        .frame(height: t.splitterWidth)
    }

    /// 两个区共用的正文。只读态用 Text（可选中），编辑态换 TextEditor 并给个边框，
    /// 让"现在能改"这件事一眼可见。
    @ViewBuilder
    private func paneBody(text: Binding<String>, editing: Bool, mono: Bool) -> some View {
        if editing {
            TextEditor(text: text)
                .font(t.font(11, design: mono ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
                .padding(6)
        } else {
            ScrollView {
                Text(text.wrappedValue)
                    .font(t.font(11, design: mono ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    /// 两个区共用的标题栏。
    ///
    /// 按钮组必须能随预览列变窄降级 —— 预览最窄只有 220pt，
    /// 挤五个带字的按钮必然折行变形（footer 已经踩过一次）。
    @ViewBuilder
    private func paneHeader<Leading: View, Trailing: View>(
        title: String,
        icon: String,
        edited: Bool,
        canEdit: Bool,
        editing: Binding<Bool>,
        copied: Bool,
        showCopy: Bool = true,
        onCopy: @escaping () -> Void,
        onRevert: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let leadingView = leading()
        let trailingView = trailing()
        HStack(spacing: 6) {
            Image(systemName: icon).font(t.font(9))
            Text(title).font(t.font(10, weight: .medium))
            if edited {
                Text("已改（不写回库）")
                    .font(t.font(9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            leadingView

            if edited {
                iconButton("arrow.uturn.backward", "复原为原始内容", action: onRevert)
            }
            if showCopy {
            iconButton(editing.wrappedValue ? "checkmark.circle" : "pencil",
                       canEdit ? (editing.wrappedValue ? "完成编辑" : "编辑（只影响这一次，不写回库）")
                               : "内容过长已截断，不能编辑",
                       disabled: !canEdit,
                       active: editing.wrappedValue) { editing.wrappedValue.toggle() }

            Button(action: onCopy) {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "已复制" : "复制")
                }
                .font(t.font(10))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(copied ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                                  : AnyShapeStyle(.primary.opacity(0.08))))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("放进系统剪贴板 —— 不粘贴，也不关面板")
            }

            trailingView
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.quaternary.opacity(0.3))
    }

    private func iconButton(_ symbol: String, _ hint: String,
                            disabled: Bool = false, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(t.font(10))
                .frame(width: t.size(18), height: t.size(16))
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(hint)
    }

    // MARK: 变换入口

    /// 命名行。默认没有名字 —— 绝大多数条目不需要，强制命名等于给每次复制加负担。
    /// 起了名的会进搜索索引，能直接搜名字找到。
    @ViewBuilder
    private func nameRow(_ item: ClipItem) -> some View {
        HStack(spacing: 5) {
            if model.namingDraft != nil {
                Image(systemName: "tag").font(t.font(9))
                InlineTextField(text: Binding(get: { model.namingDraft ?? "" },
                                              set: { model.namingDraft = $0 }),
                                placeholder: "给这条起个名字…",
                                fontSize: t.size(11),
                                onCommit: { model.commitName() },
                                onCancel: { model.cancelNaming() })
                    .frame(height: t.size(19))
                Text("⏎ 保存").font(t.font(9)).foregroundStyle(.tertiary)
            } else if let n = item.name, !n.isEmpty {
                Image(systemName: "tag.fill").font(t.font(9))
                Text(n).font(t.font(11, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Button { model.beginNaming() } label: {
                    Image(systemName: "pencil").font(t.font(9))
                }
                .buttonStyle(.plain).help("改名（⌘R）")
                Button { model.namingDraft = ""; model.commitName() } label: {
                    Image(systemName: "xmark").font(t.font(8))
                }
                .buttonStyle(.plain).help("清除名字")
                Spacer(minLength: 4)
                Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(t.font(9)).foregroundStyle(.tertiary)
            } else {
                Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(t.font(10)).foregroundStyle(.tertiary)
                Button { model.beginNaming() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "tag")
                        Text("命名")
                        Text("⌘R").foregroundStyle(.tertiary)
                    }
                    .font(t.font(9))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.primary.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("起个名字，之后可以直接搜名字找到它")
                Spacer(minLength: 4)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }

    /// 分组入口。取代原来的置顶 —— 置顶就是"只有一个、还不能改名的分组"。
    private var groupButton: some View {
        Button { model.togglePopup(.groups) } label: {
            HStack(spacing: 3) {
                Image(systemName: model.selectedItem?.groupID == nil ? "folder" : "folder.fill")
                Text(model.selectedGroupName ?? "分组")
                Text("⌘P").foregroundStyle(.tertiary)
            }
            .font(t.font(10))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(model.showGroups
                                       ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                       : AnyShapeStyle(.primary.opacity(0.08))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("放进自定义分组 —— 分组里的条目永不自动清理")
    }

    /// 变换菜单入口。**变换只影响这一次粘贴，不改库里的原始内容。**
    private var transformButton: some View {
        Button { model.togglePopup(.transforms) } label: {
            HStack(spacing: 3) {
                Image(systemName: "wand.and.rays")
                Text("变换")
                Text("⌘T").foregroundStyle(.tertiary)
            }
            .font(t.font(10))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(model.showTransforms
                                       ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                       : AnyShapeStyle(.primary.opacity(0.08))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("换一种格式粘贴出去，原始内容不变")
    }

    /// 分组菜单。⌘P 或点预览头的分组按钮打开。
    private var groupMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("放进分组…")
                .font(t.font(10)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            Divider()
            if model.groups.isEmpty {
                Text("还没有分组")
                    .font(t.font(11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(model.groups) { g in
                MenuRow { model.assignGroup(g.id) } content: {
                    Image(systemName: "folder").font(t.font(10)).foregroundStyle(.secondary)
                    Text(g.name).font(t.font(12))
                    Spacer(minLength: 12)
                    if model.selectedItem?.groupID == g.id {
                        Image(systemName: "checkmark").font(t.font(9))
                    }
                }
            }
            Divider()
            if model.selectedItem?.groupID != nil {
                MenuRow { model.assignGroup(nil) } content: {
                    Image(systemName: "folder.badge.minus").font(t.font(10))
                    Text("移出分组").font(t.font(12))
                    Spacer(minLength: 12)
                }
            }
            MenuRow { model.createGroupAndAssign() } content: {
                Image(systemName: "folder.badge.plus").font(t.font(10))
                Text("新建分组并放入").font(t.font(12))
                Spacer(minLength: 12)
            }
        }
        .frame(width: t.size(220))
        .background(RoundedRectangle(cornerRadius: 8).fill(.thickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
        .shadow(radius: 12, y: 4)
    }

    /// 变换菜单。**是对选中条目的动作，不是独立工具箱** ——
    /// 剪贴板管理器本来就站在复制与粘贴之间，在粘出去的路上转换是它天然该干的事。
    /// 选中后只把结果放进下半区，**不直接粘出去**。
    private var transformMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("处理为…")
                .font(t.font(10)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            Divider()
            ForEach(Array(model.availableTransforms.enumerated()), id: \.element.id) { _, tr in
                MenuRow { model.pickTransform(tr) } content: {
                    Text(tr.group.rawValue)
                        .font(t.font(9))
                        .foregroundStyle(.secondary)
                        .frame(width: t.size(34), alignment: .leading)
                    Text(tr.title).font(t.font(12))
                    Spacer(minLength: 12)
                    if model.activeTransform?.id == tr.id {
                        Image(systemName: "checkmark").font(t.font(9))
                    }
                }
            }
            Divider()
            Text("结果显示在下半区，确认后再粘贴")
                .font(t.font(9)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .frame(width: t.size(230))
        .background(RoundedRectangle(cornerRadius: 8).fill(.thickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
        .shadow(radius: 12, y: 4)
    }
}

// MARK: 菜单行

/// 菜单里的一行。
///
/// **必须有悬停高亮。** 没有的话鼠标划过去毫无反馈，用户不知道哪一行是"待选中"的、
/// 甚至不确定这几行能不能点 —— 系统菜单一直有这个反馈，自绘的菜单不给就显得是死的。
private struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Color.accentColor.opacity(0.22) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: 行

private struct RowView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?
    let theme: Theme

    var body: some View {
        HStack(spacing: 9) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: theme.rowThumbWidth, height: theme.rowThumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            } else {
                Image(systemName: icon)
                    .font(theme.font(13))
                    .frame(width: theme.iconColumn)
                    .foregroundStyle(selected ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // 起过名就以名字为主标题 —— 命名的意义就是"我要靠这个认出它"
                    if item.name?.isEmpty == false {
                        Image(systemName: "tag.fill").font(.system(size: 7))
                    }
                    Text(item.displayTitle.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1).font(theme.font(12))
                }
                HStack(spacing: 4) {
                    if item.groupID != nil { Image(systemName: "folder.fill").font(.system(size: 7)) }
                    if item.sensitivity == .sensitive { Image(systemName: "lock.fill").font(.system(size: 7)) }
                    Text(item.sourceAppName ?? item.kind.label)
                    Text("·")
                    Text(item.lastUsedAt, style: .relative)
                }
                .font(theme.font(9))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
            }
            Spacer(minLength: 4)
            // 来源 App 图标。文字里已经有 App 名了，但图标一眼就能扫到，
            // 找"刚才从 Chrome 复制的那条"时比读一遍名字快得多。
            if let appIcon = SourceIcon.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: theme.size(14), height: theme.size(14))
                    .opacity(selected ? 1 : 0.85)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(theme.font(9, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.65)
                                             : Color.secondary.opacity(0.45))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.accentColor : Color.clear))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 5)
    }

    private var icon: String {
        switch item.kind {
        case .image: return "photo"
        case .fileRef: return "doc"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        case .richText: return "textformat"
        case .color: return "paintpalette"
        default: return "text.alignleft"
        }
    }
}

// MARK: 搜索框

/// 承载键盘事件的搜索框。
///
/// ⚠️ 键盘处理必须走 `control(_:textView:doCommandBy:)`，**不能 override keyDown**。
///
/// NSTextField 获得焦点时，真正的 first responder 是它的 **field editor**（一个共享的
/// NSTextView），按键先到 field editor，text field 自己的 keyDown 根本收不到。
/// Esc 关不掉面板就是这么来的 —— 代码看着写了，实际从没被调用过。
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onKey: (KeyAction) -> Bool
    var fontSize: CGFloat = 14

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = "搜索剪贴板…"
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.font = .systemFont(ofSize: fontSize)
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onKey = onKey
        if nsView.font?.pointSize != fontSize { nsView.font = .systemFont(ofSize: fontSize) }
        if nsView.stringValue != text { nsView.stringValue = text }
        // 面板每次弹出都能直接打字，不用先点一下
        if nsView.window != nil, nsView.window?.firstResponder !== nsView.currentEditor() {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self, onKey: onKey) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField
        var onKey: (KeyAction) -> Bool

        init(_ p: SearchField, onKey: @escaping (KeyAction) -> Bool) {
            parent = p
            self.onKey = onKey
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        /// field editor 把按键翻译成命令选择器后回调这里。这是唯一可靠的拦截点。
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):        // esc
                return onKey(.cancel)
            case #selector(NSResponder.moveUp(_:)),
                 #selector(NSResponder.moveToBeginningOfDocument(_:)):
                return onKey(.up)
            case #selector(NSResponder.moveDown(_:)),
                 #selector(NSResponder.moveToEndOfDocument(_:)):
                return onKey(.down)
            case #selector(NSResponder.insertNewline(_:)):          // 回车
                return onKey(.confirm)
            default:
                return false
            }
        }
    }
}

enum KeyAction { case up, down, confirm, cancel, pick(Int), delete, pin, transform, pasteTransformed, rename }

