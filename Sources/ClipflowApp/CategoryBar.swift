import SwiftUI
import ClipflowCore

/// 分类条：内置分类 + 自定义分组，横向一条。
///
/// 布局是固定的三段：`◀ [可滚动的胶囊区] ▶ +`
/// **翻页箭头和 + 都不进滚动区**，永远在原地 —— 它们要是跟着滚，
/// 分组一多就找不着"加分组"的入口了（实测 + 被挤出可视区）。
///
/// 箭头**常驻布局**、按需启用，不做"装不下才插进来"：那样箭头的出现本身会改变
/// 可用宽度 → 重新测量 → 可能又不需要箭头，测量在两个状态间来回抖。
struct CategoryBar: View {

    @ObservedObject var model: PanelModel
    let theme: Theme
    private var t: Theme { theme }

    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var anchorIndex = 0
    @State private var scrollToken = 0
    @State private var renameText = ""

    private var overflowing: Bool { contentWidth > visibleWidth + 1 }

    private var chips: [PanelCategory] {
        PanelCategory.builtins + model.groups.compactMap { $0.id.map { PanelCategory.group($0) } }
    }

    var body: some View {
        HStack(spacing: 3) {
            arrow("chevron.left", step: -1)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(chips) { chip($0) }
                    }
                    .padding(.vertical, 1)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentWidthKey.self, value: g.size.width)
                    })
                }
                .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }
                .onChange(of: scrollToken) { _, _ in
                    guard chips.indices.contains(anchorIndex) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(chips[anchorIndex].id, anchor: .leading)
                    }
                }
                // 切到某个分类时把它滚进视野，否则选中的那个可能正好在视野外
                .onChange(of: model.category) { _, new in
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(new.id, anchor: .center) }
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: VisibleWidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(VisibleWidthKey.self) { visibleWidth = $0 }

            arrow("chevron.right", step: 1)
            addButton
        }
    }

    // MARK: 胶囊

    @ViewBuilder
    private func chip(_ c: PanelCategory) -> some View {
        if let gid = c.groupID, model.renamingGroup == gid {
            // 改名态。**只有双击才进得来**，且回车/Esc/点别处都能出去。
            InlineTextField(text: $renameText,
                            placeholder: "分组名",
                            fontSize: t.size(11),
                            onCommit: { model.renameGroup(gid, to: renameText) },
                            onCancel: { model.renamingGroup = nil })
                .frame(width: t.size(84), height: t.size(19))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
        } else {
            chipLabel(c)
                .contentShape(Capsule())
                // 双击写在单击前面：SwiftUI 会先给 count:2 机会，落空才走 count:1
                .onTapGesture(count: 2) { beginRename(c) }
                .onTapGesture(count: 1) { model.category = c }
                .id(c.id)
                .contextMenu {
                    if c.groupID != nil {
                        Button("重命名…") { beginRename(c) }
                        // 说清楚删的是分组这个标签、不是里面的内容，否则没人敢点
                        Button("删除分组（条目保留）", role: .destructive) {
                            if let gid = c.groupID { model.deleteGroup(gid) }
                        }
                    }
                }
        }
    }

    /// 分组胶囊和内置分类**长得完全一样**，只多一个文件夹图标 ——
    /// 长得不一样会让人以为它是另一种控件（之前它是个输入框，就被当成了输入区）。
    private func chipLabel(_ c: PanelCategory) -> some View {
        let selected = model.category == c
        let n = c.count(kinds: model.counts, groups: model.groupCounts)
        return HStack(spacing: 4) {
            if c.groupID != nil { Image(systemName: "folder.fill").font(t.font(8)) }
            Text(c.label(groups: model.groups)).font(t.font(11))
            if n > 0 {
                Text("\(n)")
                    .font(t.font(9))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.primary.opacity(0.07))))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private func beginRename(_ c: PanelCategory) {
        guard let gid = c.groupID else { return }
        renameText = c.label(groups: model.groups)
        model.renamingGroup = gid
    }

    // MARK: 固定在右侧的两个入口

    private var addButton: some View {
        Button { model.createGroup() } label: {
            Image(systemName: "plus")
                .font(t.font(10))
                .frame(width: t.size(20), height: t.size(19))
                .background(Capsule().fill(.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("新建分组（建好后双击胶囊改名）")
    }

    private func arrow(_ symbol: String, step: Int) -> some View {
        Button {
            anchorIndex = min(max(0, anchorIndex + step * 3), max(0, chips.count - 1))
            scrollToken += 1
        } label: {
            Image(systemName: symbol)
                .font(t.font(9))
                .frame(width: t.size(14), height: t.size(19))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!overflowing)
        .opacity(overflowing ? 1 : 0.2)
    }
}

private struct ContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct VisibleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
