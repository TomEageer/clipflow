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
    /// + 按钮的悬停态。胶囊各自持有自己的，避免鼠标一划整条重算。
    @State private var addHovering = false
    /// 玻璃融合用的命名空间：同一 namespace 里的玻璃元素之间才会"流"过去
    @Namespace private var glassNS

    private var overflowing: Bool { contentWidth > visibleWidth + 1 }

    private var chips: [PanelCategory] {
        PanelCategory.builtins + model.groups.compactMap { $0.id.map { PanelCategory.group($0) } }
    }

    var body: some View {
        HStack(spacing: 3) {
            arrow("chevron.left", step: -1)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    chipRow
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
                // ⚠️ **不要在 category 变化时自动滚动。**
                //
                // 用户点的胶囊本来就在他眼前，却要花 0.18s 把它滚到正中间 ——
                // 点下去东西在动、还得等一下，主观上就是"卡"。
                // 更糟的是 withAnimation 会波及同一更新周期里的其它变化，
                // 连胶囊高亮切换都被拖成 0.18s 过渡。
                // 滚动只在用户按翻页箭头时发生（那才是他要求滚动的时刻）。
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: VisibleWidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(VisibleWidthKey.self) { visibleWidth = $0 }

            arrow("chevron.right", step: 1)
            addButton
        }
    }

    /// 胶囊区。macOS 26 起包进 `GlassEffectContainer`，让玻璃元素共用一次采样。
    ///
    /// ⚠️ **容器 spacing 必须是 0。** 它表示"相距多近的玻璃要融合在一起"，
    /// 之前给了 6 而胶囊间距只有 4 → 相邻胶囊被判定为一体，
    /// 选中的强调色直接流到左右两个上去，实测非常难看。
    ///
    /// 选中态因此不做成"给玻璃染色"，而是一个**单独的、会滑动的指示器**
    /// （见 ChipView 里的 matchedGeometryEffect）：既有滑过去的效果，又不污染邻居。
    ///
    /// 老系统上就是一个普通 HStack，样式退化但功能不缺。
    @ViewBuilder
    private var chipRow: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { rawChipRow }
        } else {
            rawChipRow
        }
    }

    private var rawChipRow: some View {
        HStack(spacing: 4) { ForEach(chips) { chip($0) } }
            // 动画只挂在分类条这棵子树上 —— 挂到点击处会把"列表整批换内容"也一起
            // animate，既难看又费
            .animation(.smooth(duration: 0.24), value: model.category)
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
            ChipView(category: c,
                     label: c.label(groups: model.groups),
                     count: c.count(kinds: model.counts, groups: model.groupCounts),
                     selected: model.category == c,
                     theme: t,
                     onSelect: { model.category = c },
                     onRename: { beginRename(c) },
                     onDelete: c.groupID.map { gid in { model.deleteGroup(gid) } },
                     glassNS: glassNS)
                .id(c.id)
        }
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
                .modifier(GlassPill(selected: false, hovering: addHovering))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { addHovering = $0 }
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

/// 单个分类胶囊。
///
/// **悬停态放在每个胶囊自己身上**，不放在 CategoryBar 上 ——
/// 放在上面的话鼠标每划过一个胶囊都会让整条重算，反而卡。
private struct ChipView: View {
    let category: PanelCategory
    let label: String
    let count: Int
    let selected: Bool
    let theme: Theme
    let onSelect: () -> Void
    let onRename: () -> Void
    /// nil = 内置分类，不能改名/删除
    let onDelete: (() -> Void)?
    let glassNS: Namespace.ID

    @State private var hovering = false
    @State private var lastTap = Date.distantPast
    private var t: Theme { theme }

    var body: some View {
        HStack(spacing: 4) {
            if onDelete != nil { Image(systemName: "folder.fill").font(t.font(8)) }
            Text(label).font(t.font(11))
            if count > 0 {
                Text("\(count)")
                    .font(t.font(9))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8).padding(.vertical, 3)
        // 选中指示器：**整条只有一个**，用 matchedGeometryEffect 在胶囊之间滑过去。
        // 给每个胶囊各自染色的话，颜色会顺着玻璃容器流到相邻胶囊上（实测很丑）。
        .background {
            if selected {
                Capsule().fill(Color.accentColor)
                    .matchedGeometryEffect(id: "categorySelection", in: glassNS)
            }
        }
        .modifier(GlassPill(selected: selected, hovering: hovering,
                            glassID: category.id, namespace: glassNS))
        .foregroundStyle(selected ? Color.white : Color.primary)
        // 只给"选中态"这一个属性加动画，不是给整次 category 变更加 ——
        // 后者会把列表整批换内容也一起 animate，既难看又费。
        .animation(.smooth(duration: 0.26), value: selected)
        .contentShape(Capsule())
        // ⚠️ **绝不能用 `onTapGesture(count: 2)`。** 只要挂了它，单击就得等双击超时
        // 才能确认（系统那一档，默认 0.5s）—— 实测点一下 370ms 才有反应。
        //
        // 也不能用 NSView 覆盖层来读 clickCount：盖在上面会吞掉鼠标，
        // 玻璃的 `.interactive()` 收不到 hover，"水滴"反馈就完全没了；
        // 放到 background 又收不到点击（实测点了完全没反应）。
        //
        // 所以按 AppKit 的语义自己判：单击**立即**生效，
        // 第二下若落在系统双击间隔内再补一个改名动作。零等待，且不挡玻璃。
        .onTapGesture {
            let now = Date()
            if onDelete != nil, now.timeIntervalSince(lastTap) < NSEvent.doubleClickInterval {
                onRename()
            } else {
                onSelect()
            }
            lastTap = now
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if let onDelete {
                Button("重命名…", action: onRename)
                // 说清楚删的是分组这个标签、不是里面的内容，否则没人敢点
                Button("删除分组（条目保留）", role: .destructive, action: onDelete)
            }
        }
    }
}

/// 胶囊背景。
///
/// macOS 26 起用 Liquid Glass（`glassEffect`），**但部署目标是 macOS 14**，
/// 所以必须走可用性分支：老系统上退回普通的半透明胶囊，样式一致、不缺功能。
/// 直接调新 API 会让老系统上的用户连 App 都起不来。
private struct GlassPill: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var glassID: String? = nil
    var namespace: Namespace.ID? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // 不给玻璃染色：染色会顺着容器流到相邻胶囊上。选中色交给上层的滑动指示器。
            let glass = content.glassEffect(.regular.interactive(), in: .capsule)
            if let glassID, let namespace {
                glass.glassEffectID(glassID, in: namespace)
            } else {
                glass
            }
        } else {
            content.background(
                Capsule().fill(AnyShapeStyle(.primary.opacity(hovering ? 0.16 : 0.07))))
        }
    }
}
