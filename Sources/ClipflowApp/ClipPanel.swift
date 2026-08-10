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
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
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
            else if let c = event.charactersIgnoringModifiers?.lowercased().first {
                if c.isNumber, c != "0" { action = .pick(Int(String(c))! - 1) }
                else if c == "p" { action = .pin }
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

    /// 面板开在鼠标左侧时为 true：列表与预览左右对调，让列表贴着鼠标。
    private var mirrored: Bool { model.mirrored }

    var body: some View {
        HStack(spacing: 0) {
            if mirrored {
                PreviewPane(model: model).frame(width: 320)
                Divider().opacity(0.5)
            }

            listColumn

            if !mirrored {
                Divider().opacity(0.5)
                PreviewPane(model: model).frame(width: 320)
            }
        }
        .frame(width: 700, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }

    private var listColumn: some View {
            VStack(spacing: 0) {
                searchBar
                Divider().opacity(0.5)

                if model.items.isEmpty {
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                            .font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text(model.query.isEmpty ? "还没有记录任何内容" : "没有匹配结果")
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
                                            thumbnail: model.thumbnail(for: item))
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
            .frame(width: 380)
    }

    private var searchBar: some View {
        SearchField(text: $model.query, onKey: model.handleKey)
            .padding(.horizontal, 12)
            .padding(.top, 10).padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.total) 条")
            Spacer()
            KeyHint("↑↓", "选择")
            KeyHint("⏎", "粘贴")
            KeyHint("⌘P", model.selectedIsPinned ? "取消置顶" : "置顶")
            KeyHint("⌘⌫", "删除")
        }
        .font(.system(size: 10))
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
    }
}

// MARK: 预览

private struct PreviewPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                            if item.sensitivity == .sensitive {
                                Label("敏感", systemImage: "lock.fill")
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            }
                            Text(item.kind.label)
                            Text("·")
                            Text(item.sourceAppName ?? "未知来源")
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 8)

                    Divider().opacity(0.4)

                    ScrollView {
                        if let big = model.largePreview(for: item) {
                            Image(nsImage: big)
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .padding(10)
                        } else {
                            Text(model.fullText(for: item))
                                .font(.system(size: 11,
                                              design: item.kind == .code ? .monospaced : .default))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }

                    Divider().opacity(0.4)
                    Text(model.formatSummary(for: item))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
            } else {
                VStack { Spacer()
                    Text("选中一条查看").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: 行

private struct RowView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 9) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 34)
                    .foregroundStyle(selected ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1).font(.system(size: 12))
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill").font(.system(size: 7)) }
                    if item.sensitivity == .sensitive { Image(systemName: "lock.fill").font(.system(size: 7)) }
                    Text(item.sourceAppName ?? item.kind.label)
                    Text("·")
                    Text(item.lastUsedAt, style: .relative)
                }
                .font(.system(size: 9))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
            }
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, design: .rounded))
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

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = "搜索剪贴板…"
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.font = .systemFont(ofSize: 14)
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onKey = onKey
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

enum KeyAction { case up, down, confirm, cancel, pick(Int), delete, pin }
