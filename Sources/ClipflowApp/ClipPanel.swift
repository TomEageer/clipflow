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

    /// 定位到鼠标旁，并算出展开方向。
    ///
    /// **跟随鼠标的目的是让鼠标少动。**
    ///
    /// 面板默认开在鼠标右侧，列表在左半边 —— 紧挨鼠标。
    /// 但到了屏幕右边缘，面板只能开在鼠标左侧，此时鼠标在面板的**右**边，
    /// 而列表还在最左边，等于隔着整个预览面板，跟随就白做了。
    /// 所以这时把**列表和预览左右对调**，让可点击的列表始终贴着鼠标那一侧。
    ///
    /// 只镜像左右，不做上下反转 —— 列表倒序违反阅读直觉。
    @discardableResult
    func positionAtCursor() -> Anchor {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        let gap: CGFloat = 8

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 下方放得下就往下开，否则往上
        let fitsBelow = (mouse.y - gap - size.height) >= visible.minY
        // 右侧放得下就往右开，否则往左
        let fitsRight = (mouse.x + gap + size.width) <= visible.maxX

        var origin = NSPoint(
            x: fitsRight ? mouse.x + gap : mouse.x - gap - size.width,
            y: fitsBelow ? mouse.y - gap - size.height : mouse.y + gap
        )
        // 兜底钳制（比如屏幕比面板还小）
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        setFrameOrigin(origin)

        anchor = fitsRight ? .right : .left
        return anchor
    }

    /// 记住用户拉过的尺寸。下次唤出保持一致，不然每次都要重拉一遍。
    var onResize: ((NSSize) -> Void)?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let changed = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if changed, isVisible { onResize?(frameRect.size) }
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

    /// 分类切换。用原生分段控件，点击切换，不自动跳。
    private var categoryBar: some View {
        Picker("", selection: $model.category) {
            ForEach(PanelCategory.allCases) { c in
                let n = c.count(from: model.counts)
                Text(n > 0 ? "\(c.label) \(n)" : c.label).tag(c)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        SearchField(text: $model.query, onKey: model.handleKey, fontSize: t.size(14))
            .padding(.horizontal, 12)
            .padding(.top, 10).padding(.bottom, 8)
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
        h.append(("⌘P", model.selectedIsPinned ? "取消置顶" : "置顶"))
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
    /// 相对按下点的**累计**位移（与 DragGesture.translation 同语义）
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onDrag = onDrag
        v.onEnd = onEnd
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) {
        v.onDrag = onDrag
        v.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startX: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .cursorUpdate, .inVisibleRect],
                owner: self))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(event.locationInWindow.x - startX)
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

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if item.pinned { Image(systemName: "pin.fill").font(t.font(9)) }
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
                            if !model.availableTransforms.isEmpty { transformButton }
                        }
                        .font(t.font(10)).foregroundStyle(.secondary)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                            .font(t.font(10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 8)

                    Divider().opacity(0.4)

                    if let big = model.largePreview(for: item) {
                        imagePane(big, item: item)
                    } else if model.processedText != nil {
                        // 上下两块：原文在上、处理结果在下。
                        // 原来是靠一个「格式化 / 原文」开关来回切，看不到两者的对照，
                        // 而变换本身又是点一下直接粘出去 —— 等于粘了才知道结果对不对。
                        VStack(spacing: 0) {
                            textPane(item, label: "原文", text: model.fullText(for: item))
                            Divider()
                            processedPane(item)
                        }
                    } else {
                        textPane(item, label: nil, text: model.fullText(for: item))
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
                .overlay(alignment: .topTrailing) {
                    if model.showTransforms {
                        transformMenu.padding(.top, t.size(30)).padding(.trailing, 8)
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

    private func textPane(_ item: ClipItem, label: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .font(t.font(9)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            }
            ScrollView {
                Text(text)
                    .font(t.font(11, design: item.kind == .code ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, label == nil ? 12 : 4)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 下半区：处理结果 + 就地粘贴入口。
    private func processedPane(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(t.font(9))
                Text(model.activeTransform?.title ?? "处理结果")
                    .font(t.font(10, weight: .medium))
                Spacer(minLength: 6)
                Button { model.pasteTransformed() } label: {
                    HStack(spacing: 3) {
                        Text("粘贴这个")
                        Text("⌘⏎").foregroundStyle(.tertiary)
                    }
                    .font(t.font(10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.primary.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("把处理结果粘出去，库里的原始内容不变")
                Button { model.clearTransform() } label: {
                    Image(systemName: "xmark").font(t.font(9))
                }
                .buttonStyle(.plain)
                .help("收起处理结果")
            }
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))

            ScrollView {
                Text(model.processedText ?? "")
                    .font(t.font(11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 变换入口

    /// 变换菜单入口。**变换只影响这一次粘贴，不改库里的原始内容。**
    private var transformButton: some View {
        Button { model.showTransforms.toggle() } label: {
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
                Button {
                    model.pickTransform(tr)
                } label: {
                    HStack(spacing: 8) {
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
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1).font(theme.font(12))
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill").font(.system(size: 7)) }
                    if item.sensitivity == .sensitive { Image(systemName: "lock.fill").font(.system(size: 7)) }
                    Text(item.sourceAppName ?? item.kind.label)
                    Text("·")
                    Text(item.lastUsedAt, style: .relative)
                }
                .font(theme.font(9))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
            }
            Spacer(minLength: 4)
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

enum KeyAction { case up, down, confirm, cancel, pick(Int), delete, pin, transform, pasteTransformed }
