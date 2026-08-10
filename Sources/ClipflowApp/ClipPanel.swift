import AppKit
import SwiftUI
import ClipflowCore

/// 鼠标旁弹出的面板。
final class ClipPanel: NSPanel {

    /// 点击面板外部时关闭。剪贴板面板是"用完即走"的，只能按 Esc 关很生硬。
    private var outsideClickMonitor: Any?
    var onDismiss: (() -> Void)?

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

    /// 定位到鼠标旁，跨屏边界钳制。
    func positionAtCursor() {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        var origin = NSPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // 下方放不下就翻到鼠标上方，而不是硬贴着屏幕底边
            if origin.y < visible.minY + 4 {
                origin.y = min(mouse.y + 8, visible.maxY - size.height - 4)
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        setFrameOrigin(origin)
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
    }

    /// 淡出。比淡入更快 —— 关闭要干脆，拖泥带水最影响手感。
    func fadeOut(completion: (() -> Void)? = nil) {
        stopOutsideClickMonitor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        }
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
}

// MARK: - 面板内容

struct ClipListView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 0) {
            // ── 左：列表
            VStack(spacing: 0) {
                SearchField(text: $model.query, onKey: model.handleKey)
                    .padding(.horizontal, 12)
                    .padding(.top, 10).padding(.bottom, 8)

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
                        .onChange(of: model.selection) { _, new in
                            guard new < model.items.count else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(model.items[new].id, anchor: .center)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                footer
            }
            .frame(width: 380)

            Divider().opacity(0.5)

            // ── 右：选中项预览。选中了看不到全貌，是判断"是不是这条"最大的障碍
            PreviewPane(model: model)
                .frame(width: 320)
        }
        .frame(width: 700, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
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

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onKey: (KeyAction) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let tf = KeyCatchingTextField()
        tf.placeholderString = "搜索剪贴板…"
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.onKey = onKey
        tf.font = .systemFont(ofSize: 14)
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        (nsView as? KeyCatchingTextField)?.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
    }
}

enum KeyAction { case up, down, confirm, cancel, pick(Int), delete, pin }

private final class KeyCatchingTextField: NSTextField {
    var onKey: ((KeyAction) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        var action: KeyAction?

        if cmd {
            if event.keyCode == 51 { action = .delete }            // ⌘⌫
            else if let c = event.charactersIgnoringModifiers?.lowercased().first {
                if c.isNumber, c != "0" { action = .pick(Int(String(c))! - 1) }
                else if c == "p" { action = .pin }
            }
        }
        if action == nil {
            switch event.keyCode {
            case 126: action = .up
            case 125: action = .down
            case 36, 76: action = .confirm
            case 53: action = .cancel
            default: break
            }
        }
        if let action, onKey?(action) == true { return }
        super.keyDown(with: event)
    }
}
