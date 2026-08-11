import SwiftUI
import ClipflowCore

/// 分类条：内置分类 + 自定义分组，横向一条。
///
/// **翻页按钮只在真装不下时出现。** 分组数量不固定，条目多了必然溢出；
/// 但大多数人只有两三个分组，那时候还常驻两个箭头纯属白占地方、还让人以为有隐藏内容。
/// 用 GeometryReader 量出「内容宽 vs 可用宽」再决定。
struct CategoryBar: View {

    @ObservedObject var model: PanelModel
    let theme: Theme
    private var t: Theme { theme }

    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var renameText = ""

    private var overflowing: Bool { contentWidth > visibleWidth + 1 }

    private var chips: [PanelCategory] {
        PanelCategory.builtins + model.groups.compactMap { $0.id.map { PanelCategory.group($0) } }
    }

    var body: some View {
        HStack(spacing: 4) {
            if overflowing { pageButton("chevron.left", forward: false) }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(chips) { c in chip(c) }
                        addButton
                    }
                    .padding(.vertical, 1)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: WidthKey.self, value: g.size.width)
                    })
                    .onPreferenceChange(WidthKey.self) { contentWidth = $0 }
                }
                .onChange(of: pageToken) { _, _ in
                    guard let target = pageTarget else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
                }
                // 切到某个分类时把它滚进视野，否则点了翻页选中的那个可能又被挤出去
                .onChange(of: model.category) { _, new in
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(new.id, anchor: .center) }
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: VisibleWidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(VisibleWidthKey.self) { visibleWidth = $0 }

            if overflowing { pageButton("chevron.right", forward: true) }
        }
    }

    // MARK: 胶囊

    @ViewBuilder
    private func chip(_ c: PanelCategory) -> some View {
        let selected = model.category == c
        let n = c.count(kinds: model.counts, groups: model.groupCounts)
        let isRenaming = c.groupID != nil && model.renamingGroup == c.groupID

        if isRenaming, let gid = c.groupID {
            // 就地改名。新建分组后自动进这个状态 —— 没人想留着「分组 3」这个名字。
            TextField("分组名", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .font(t.font(11))
                .frame(width: t.size(90))
                .onSubmit { model.renameGroup(gid, to: renameText) }
                .onAppear { renameText = c.label(groups: model.groups) }
                .onExitCommand { model.renamingGroup = nil }
        } else {
            Button { model.category = c } label: {
                HStack(spacing: 4) {
                    if c.groupID != nil {
                        Image(systemName: "folder.fill").font(t.font(8))
                    }
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
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .id(c.id)
            .contextMenu {
                if let gid = c.groupID {
                    Button("重命名…") {
                        renameText = c.label(groups: model.groups)
                        model.renamingGroup = gid
                    }
                    // 删的是分组这个标签，不是里面的内容 —— 说清楚，免得没人敢点
                    Button("删除分组（条目保留）", role: .destructive) { model.deleteGroup(gid) }
                }
            }
        }
    }

    private var addButton: some View {
        Button { model.createGroup() } label: {
            Image(systemName: "plus")
                .font(t.font(9))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Capsule().fill(.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("新建分组")
    }

    // MARK: 翻页

    @State private var pageToken = 0
    @State private var pageTarget: String?

    private func pageButton(_ symbol: String, forward: Bool) -> some View {
        Button {
            let all = chips
            let idx = all.firstIndex { $0 == model.category } ?? 0
            // 一次翻大约半屏的量，别一次跳到头
            let step = max(2, all.count / 3)
            let next = forward ? min(all.count - 1, idx + step) : max(0, idx - step)
            pageTarget = all[next].id
            pageToken += 1
        } label: {
            Image(systemName: symbol)
                .font(t.font(9))
                .frame(width: t.size(16), height: t.size(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct VisibleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
