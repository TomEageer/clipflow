import SwiftUI
import ClipflowCore
import UniformTypeIdentifiers

/// 分类条：**两排**。
///
/// - 第一排：类型标签（显示哪些由设置页决定）
/// - 第二排：用户自建分组，可拖动排序，右端固定一个「+」
///
/// 分两排是因为它们的性质根本不同：类型标签是**闭集**，分组是**用户随时会加的开集**。
/// 挤在一排时分组一多就把类型标签顶出可视区，找「图片」还得先翻页。
///
/// 两排都用同一个 `ChipScrollRow`：**装不下就能滑**。
/// 之前第一排图省事没套滚动容器，结果类型标签一勾多就溢出 ——
/// HStack 里的胶囊都是 `fixedSize`、压不动，于是整排被居中裁掉两头，
/// 左边的「全部」直接看不见了。
///
/// ⚠️ **这里不用 Liquid Glass（`glassEffect` / `GlassEffectContainer`）。**
/// 试过，结论是不划算：每个胶囊一层实时背景模糊（每次切换多 15~68ms 渲染）、
/// 容器会把相邻玻璃融合导致选中色流到隔壁、而且只有 macOS 26+ 才有。
/// 普通胶囊一套代码通吃 macOS 14 到最新，还更快。**不要再加回来。**
struct CategoryBar: View {

    @ObservedObject var model: PanelModel
    let theme: Theme
    private var t: Theme { theme }

    @State private var renameText = ""
    @State private var addHovering = false

    private var groupChips: [PanelCategory] {
        model.groups.compactMap { $0.id.map { PanelCategory.group($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 第一排：类型标签
            ChipScrollRow(categories: model.visibleCategories, theme: t) { c in
                ChipView(label: c.label(groups: model.groups),
                         count: c.count(kinds: model.counts, groups: model.groupCounts),
                         selected: model.category == c,
                         theme: t,
                         onSelect: { model.category = c },
                         onRename: {}, onDelete: nil)
                    // 「全部」不参与排序：它恒定在最前，拖走了反而找不着
                    .draggable(c == .all ? "" : c.id) {
                        Text(c.label(groups: model.groups))
                            .font(t.font(11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.thickMaterial))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let from = items.first, !from.isEmpty else { return false }
                        model.moveCategory(from, before: c.id)
                        return true
                    }
            } trailing: {
                EmptyView()
            }

            // 第二排：自定义分组
            ChipScrollRow(categories: groupChips, theme: t,
                          emptyHint: "还没有分组，点右边的 + 新建") { c in
                groupChip(c)
            } trailing: {
                addButton
            }
        }
    }

    @ViewBuilder
    private func groupChip(_ c: PanelCategory) -> some View {
        let gid = c.groupID ?? 0
        if model.renamingGroup == gid {
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
            ChipView(label: c.label(groups: model.groups),
                     count: c.count(kinds: model.counts, groups: model.groupCounts),
                     selected: model.category == c,
                     theme: t,
                     onSelect: { model.category = c },
                     onRename: { beginRename(c) },
                     onDelete: { model.deleteGroup(gid) })
                // 拖动排序。传的是分组 id 的字符串 —— 只在本进程内用，
                // 不需要自定义 UTType，String 自带 Transferable。
                //
                // ⚠️ **拖拽预览里绝不能改 @State**（比如用 onAppear 记"正在拖谁"）：
                // 预览在视图构建期求值，改 state → 触发重建 → 预览再求值 …… 死循环。
                // 实测表现是主线程持续空转、面板淡入动画永远跑不完。
                .draggable("\(gid)") {
                    Text(c.label(groups: model.groups))
                        .font(t.font(11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.thickMaterial))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let s = items.first, let from = Int64(s) else { return false }
                    model.moveGroup(from, before: gid)
                    return true
                }
        }
    }

    private func beginRename(_ c: PanelCategory) {
        guard let gid = c.groupID else { return }
        renameText = c.label(groups: model.groups)
        model.renamingGroup = gid
    }

    private var addButton: some View {
        Button { model.createGroup() } label: {
            Image(systemName: "plus")
                .font(t.font(10))
                .frame(width: t.size(20), height: t.size(19))
                .background(Capsule().fill(.primary.opacity(addHovering ? 0.16 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { addHovering = $0 }
        .help("新建分组（建好后双击胶囊改名，拖动可排序）")
    }
}

// MARK: - 可滚动的一排胶囊

/// 一排胶囊：`◀ [可横向滚动的胶囊区] ▶ [固定尾部]`
///
/// **翻页箭头和尾部按钮都不进滚动区**，永远在原地 —— 它们要是跟着滚，
/// 内容一多就找不着入口了（实测「+」被挤出可视区）。
///
/// 箭头**恒定可用，不做"装得下就置灰"**。
///
/// 判断"装不装得下"要在滚动内容和容器上各挂一个 GeometryReader + preference，
/// 而这两处测量会持续喂 SwiftUI 的布局循环 —— 实测两排各两个测量之后，
/// 面板打开时主线程 CPU 从 ~20% 涨到 **38.8%**。
/// 为了让箭头在不需要时灰一下而付出这个代价，完全不划算：
/// 装得下时按箭头只是 scrollTo 一个已经在视野里的元素，什么都不会发生。
private struct ChipScrollRow<Chip: View, Trailing: View>: View {

    let categories: [PanelCategory]
    let theme: Theme
    var emptyHint: String? = nil
    @ViewBuilder let chip: (PanelCategory) -> Chip
    @ViewBuilder let trailing: () -> Trailing

    @State private var anchorIndex = 0
    @State private var scrollToken = 0

    private var t: Theme { theme }

    var body: some View {
        HStack(spacing: 3) {
            arrow("chevron.left", step: -1)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // ⚠️ 选中态**不加动画**。任何过渡都意味着"点下去要等它演完"，
                    // 分类切换是高频操作，即时比好看重要。
                    HStack(spacing: 4) {
                        if categories.isEmpty, let emptyHint {
                            Text(emptyHint)
                                .font(t.font(10)).foregroundStyle(.tertiary)
                                .padding(.vertical, 3)
                        }
                        ForEach(categories) { c in
                            chip(c).id(c.id)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onChange(of: scrollToken) { _, _ in
                    guard categories.indices.contains(anchorIndex) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(categories[anchorIndex].id, anchor: .leading)
                    }
                }
                // ⚠️ **不要在 category 变化时自动滚动。**
                // 用户点的胶囊本来就在他眼前，却要花 0.18s 把它滚到正中间 ——
                // 点下去东西在动、还得等一下，主观上就是"卡"。
                // 滚动只在用户按翻页箭头时发生（那才是他要求滚动的时刻）。
            }

            arrow("chevron.right", step: 1)
            trailing()
        }
    }

    private func arrow(_ symbol: String, step: Int) -> some View {
        Button {
            anchorIndex = min(max(0, anchorIndex + step * 3), max(0, categories.count - 1))
            scrollToken += 1
        } label: {
            Image(systemName: symbol)
                .font(t.font(9))
                .frame(width: t.size(14), height: t.size(19))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(categories.count <= 1)
    }
}

// MARK: - 单个胶囊

/// **悬停态放在每个胶囊自己身上**，不放在 CategoryBar 上 ——
/// 放在上面的话鼠标每划过一个胶囊都会让整条重算，反而卡。
private struct ChipView: View {
    let label: String
    let count: Int
    let selected: Bool
    let theme: Theme
    let onSelect: () -> Void
    let onRename: () -> Void
    /// nil = 类型标签，不能改名/删除/拖动
    let onDelete: (() -> Void)?

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
        .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.primary.opacity(hovering ? 0.16 : 0.07))))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Capsule())
        // ⚠️ **绝不能用 `onTapGesture(count: 2)`。** 只要挂了它，单击就得等双击超时
        // 才能确认（系统那一档，默认 0.5s）—— 实测点一下 370ms 才有反应。
        //
        // 也不能用 NSView 覆盖层来读 clickCount：盖在上面会吞掉鼠标（悬停就没了），
        // 放到 background 又收不到点击。都试过，都不行。
        //
        // 所以按 AppKit 的语义自己判：单击**立即**生效，
        // 第二下若落在系统双击间隔内再补一个改名动作。零等待。
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
