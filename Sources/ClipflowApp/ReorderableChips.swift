import SwiftUI

/// 可拖动重排的一排胶囊，带 Apple 那套反馈：
/// **拖起来的抬高带阴影 → 经过的胶囊实时让位 → 松手弹到目标槽位。**
///
/// 为什么不用 `.draggable` / `.dropDestination`：那套只在**松手那一刻**才回调，
/// 拖动过程中其它胶囊纹丝不动，等于没有反馈 —— 用户完全不知道会落到哪。
/// 要做"挤开"就必须自己跟手势、实时改数组顺序。
///
/// ⚠️ 前提是 `PanelHostingView` 已经关掉了窗口背景拖拽，
/// 否则 AppKit 会先把 mouseDown 当成"拖窗口"，SwiftUI 手势根本收不到。
struct ReorderableRow<Item: Identifiable & Equatable, Content: View>: View
where Item.ID == String {

    let items: [Item]
    /// 不参与排序的 id（比如「全部」，它恒定在最前）
    var pinnedIDs: Set<String> = []
    /// 把 `id` 移到 `target` 当前的位置
    let move: (String, String) -> Void
    /// 松手时调用，用来落库
    let commit: () -> Void
    @ViewBuilder let content: (Item) -> Content

    /// 布局位置。**放在 class 里而不是 @State** —— 每次布局都写一次，
    /// 写 @State 会触发重渲染，进而又触发布局，白白空转。
    @State private var frames = FrameBox()
    @State private var dragging: String?
    @State private var pointerX: CGFloat = 0

    private static var space: String { "reorderable-row" }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let isDragging = dragging == item.id
                content(item)
                    .background(measure(item.id))
                    .offset(x: isDragging ? offset(for: item.id) : 0)
                    .scaleEffect(isDragging ? 1.07 : 1)
                    .shadow(color: .black.opacity(isDragging ? 0.28 : 0),
                            radius: isDragging ? 7 : 0, y: isDragging ? 3 : 0)
                    .zIndex(isDragging ? 1 : 0)
                    .gesture(gesture(for: item.id))
            }
        }
        .coordinateSpace(name: Self.space)
        // 让位与吸附都走同一条弹簧：松手时偏移归零，胶囊自然"吸"到新槽位
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: items.map(\.id))
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: dragging)
    }

    // MARK: 手势

    private func gesture(for id: String) -> some Gesture {
        // minimumDistance 给 4pt：小于这个距离仍算点击，不会一碰就进入拖动
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { v in
                guard !pinnedIDs.contains(id) else { return }
                if dragging != id { dragging = id }
                pointerX = v.location.x
                if let target = targetID(under: v.location.x, dragging: id), target != id {
                    move(id, target)
                }
            }
            .onEnded { _ in
                guard dragging != nil else { return }
                dragging = nil
                commit()
            }
    }

    /// 拖动中的胶囊要跟着指针走：偏移 = 指针位置 − 它当前槽位的中心。
    /// 一旦发生让位、槽位中心跟着变，这个差值自动收敛 —— 胶囊始终贴着指针。
    private func offset(for id: String) -> CGFloat {
        guard let f = frames.value[id] else { return 0 }
        return pointerX - f.midX
    }

    /// 指针底下是哪个胶囊。只认中心点，避免在边界上来回抖。
    private func targetID(under x: CGFloat, dragging id: String) -> String? {
        var best: (id: String, dist: CGFloat)?
        for item in items where !pinnedIDs.contains(item.id) {
            guard let f = frames.value[item.id] else { continue }
            let d = abs(f.midX - x)
            if best == nil || d < best!.dist { best = (item.id, d) }
        }
        return best?.id
    }

    private func measure(_ id: String) -> some View {
        GeometryReader { g in
            let f = g.frame(in: .named(Self.space))
            Color.clear
                .onAppear { frames.value[id] = f }
                .onChange(of: f) { _, new in frames.value[id] = new }
        }
    }
}

/// 布局位置的存放处。**故意用引用类型**：写它不会让 SwiftUI 认为状态变了，
/// 也就不会因为"每次布局都记一遍位置"而触发重渲染 → 再触发布局的空转。
@Observable
private final class FrameBox {
    var value: [String: CGRect] = [:]
}
