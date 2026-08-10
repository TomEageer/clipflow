import AppKit
import SwiftUI
import ClipflowCore

/// 鼠标旁弹出的面板。
///
/// 用 `NSPanel` + `.nonactivatingPanel`：弹出时**不抢前台 App 的焦点**，
/// 这样关闭面板后不需要等焦点还回去，粘贴时序简单得多。
final class ClipPanel: NSPanel {

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
        // 全屏 Space 与 Stage Manager 下也能出现
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    // nonactivating panel 默认不能成为 key window，但我们需要键盘输入（搜索/上下选择）
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 定位到鼠标旁，并做跨屏边界钳制。
    func positionAtCursor() {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        // 面板出现在鼠标下方偏右一点，避免光标压住第一行
        var origin = NSPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        setFrameOrigin(origin)
    }
}

// MARK: - 面板内容

struct ClipListView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.query, onKey: model.handleKey)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()

            if model.items.isEmpty {
                VStack {
                    Spacer()
                    Text(model.query.isEmpty ? "还没有记录任何内容" : "没有匹配结果")
                        .foregroundStyle(.secondary).font(.system(size: 12))
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                RowView(item: item, index: idx, selected: idx == model.selection,
                                        thumbnail: model.thumbnail(for: item))
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.select(idx); model.confirm() }
                            }
                        }
                    }
                    .onChange(of: model.selection) { _, new in
                        if new < model.items.count {
                            proxy.scrollTo(model.items[new].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Label("\(model.total) 条", systemImage: "tray.full")
                Spacer()
                Text("↑↓ 选择   ⏎ 粘贴   esc 关闭")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: 460, height: 420)
        .background(.ultraThinMaterial)
    }
}

private struct RowView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail {
                // 图片直接给预览 —— 「[图片 278 KB]」这种文字对用户毫无意义
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                Image(systemName: icon)
                    .frame(width: 40)
                    .foregroundStyle(selected ? Color.white : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .font(.system(size: 12))
                HStack(spacing: 6) {
                    if item.sensitivity == .sensitive {
                        Image(systemName: "lock.fill").font(.system(size: 8))
                    }
                    Text(item.sourceAppName ?? item.kind.label)
                    Text("·")
                    Text(item.createdAt, style: .relative)
                }
                .font(.system(size: 9))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear)
        .foregroundStyle(selected ? Color.white : Color.primary)
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

/// 承载键盘事件的搜索框。用 NSViewRepresentable 是因为 SwiftUI 的 TextField
/// 拿不到 ↑↓/Esc 这些我们需要拦截的按键。
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onKey: (KeyAction) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let tf = KeyCatchingTextField()
        tf.placeholderString = "搜索剪贴板…"
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.onKey = onKey
        tf.font = .systemFont(ofSize: 13)
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

enum KeyAction { case up, down, confirm, cancel, pick(Int) }

private final class KeyCatchingTextField: NSTextField {
    var onKey: ((KeyAction) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let action: KeyAction?
        if event.modifierFlags.contains(.command),
           let c = event.charactersIgnoringModifiers?.first, c.isNumber, c != "0" {
            action = .pick(Int(String(c))! - 1)
        } else {
            switch event.keyCode {
            case 126: action = .up        // ↑
            case 125: action = .down      // ↓
            case 36, 76: action = .confirm // ⏎ / 小键盘 ⏎
            case 53: action = .cancel     // esc
            default: action = nil
            }
        }
        if let action, onKey?(action) == true { return }
        super.keyDown(with: event)
    }
}
