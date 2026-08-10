import AppKit
import SwiftUI
import ClipflowCore

/// 设置与管理窗口。三个标签页：通用 / 历史 / 存储。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let store: ClipflowStore
    private let model: SettingsModel

    init(store: ClipflowStore) {
        self.store = store
        self.model = SettingsModel(store: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Clipflow 设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.refresh()
        // 设置窗口是"正经窗口"，需要正常激活，与浮窗面板不同
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 兜底：如果用户在录制中途直接关窗口，热键处于已注销状态，必须恢复，
        // 否则会永久失去唤出面板的能力（还找不到原因）。
        _ = AppDelegate.resumeHotKey()
        // 关掉后退回菜单栏模式，别在 Dock 里留个图标
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {

    @Published var settings: ClipflowSettings {
        didSet { settings.save() }
    }
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var breakdown: [(kind: ClipKind, count: Int, bytes: Int)] = []
    @Published private(set) var stats: ClipflowStore.Stats?
    @Published var kindFilter: ClipKind? { didSet { refreshList() } }
    @Published var query: String = "" { didSet { refreshList() } }
    @Published var selected: Set<ClipItem.ID> = []
    @Published var lastAction: String = ""
    /// 显示**实际生效**的组合，不是"保存过的那个"。注册失败时两者会不一致，
    /// 显示保存值等于界面在骗人。
    @Published var hotKey: HotKeyCombo = AppDelegate.currentActiveCombo() ?? HotKeyCombo.load()
    @Published var hotKeyOK: Bool = true

    func syncHotKey() {
        hotKey = AppDelegate.currentActiveCombo() ?? HotKeyCombo.load()
    }

    let store: ClipflowStore

    init(store: ClipflowStore) {
        self.store = store
        self.settings = ClipflowSettings.load()
    }

    func refresh() {
        syncHotKey()
        refreshList()
        breakdown = (try? store.breakdownByKind()) ?? []
        stats = try? store.stats()
    }

    func refreshList() {
        items = (try? store.browse(sort: .recentlyUsed, kind: kindFilter, query: query)) ?? []
        selected = selected.filter { id in items.contains { $0.id == id } }
    }

    func deleteSelected() {
        guard !selected.isEmpty else { return }
        let n = selected.count
        try? store.deleteIDs(selected.compactMap { $0 })
        selected.removeAll()
        refresh()
        lastAction = "已删除 \(n) 条"
    }

    func deleteAll(keepPinned: Bool) {
        let n = (try? store.deleteAll(keepPinned: keepPinned)) ?? 0
        refresh()
        lastAction = "已清空 \(n) 条\(keepPinned ? "（置顶已保留）" : "")"
    }

    /// 按当前设置清理 + 回收孤儿 blob
    func runCleanup() {
        guard let r = try? store.cleanup(settings: settings) else { return }
        let v = (try? store.vacuumBlobs()) ?? (0, 0)
        try? store.optimize()
        refresh()
        let f = ByteCountFormatter()
        lastAction = "清理 \(r.total) 条（保留期 \(r.byRetention) · 敏感 \(r.bySensitiveTTL) · "
            + "超量 \(r.byMaxItems + r.byStorage)）；回收孤儿附件 \(v.0) 个，"
            + "共释放 \(f.string(fromByteCount: Int64(r.freedBytes + v.1)))"
    }

    func vacuumOnly() {
        let v = (try? store.vacuumBlobs()) ?? (0, 0)
        try? store.optimize()
        refresh()
        let f = ByteCountFormatter()
        lastAction = "回收孤儿附件 \(v.0) 个，释放 \(f.string(fromByteCount: Int64(v.1)))"
    }

    private var thumbCache: [String: NSImage] = [:]

    func thumbnail(for item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let c = thumbCache[item.contentHash] { return c }
        guard let png = store.thumbnail(for: item), let img = NSImage(data: png) else { return nil }
        if thumbCache.count > 400 { thumbCache.removeAll(keepingCapacity: true) }
        thumbCache[item.contentHash] = img
        return img
    }

    func formatSummary(for item: ClipItem) -> String {
        guard let id = item.id, let reps = try? store.representations(of: id) else { return "" }
        let f = ByteCountFormatter()
        return reps.sorted { $0.byteSize > $1.byteSize }.prefix(4)
            .map { "\($0.uti.replacingOccurrences(of: "public.", with: "")) \(f.string(fromByteCount: Int64($0.byteSize)))" }
            .joined(separator: "  ")
    }

    func revealDataFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.paths.root.path)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("通用", systemImage: "gearshape") }
            HistoryTab(model: model).tabItem { Label("历史记录", systemImage: "clock.arrow.circlepath") }
            StorageTab(model: model).tabItem { Label("存储", systemImage: "internaldrive") }
        }
        .frame(minWidth: 780, minHeight: 520)
        .overlay(alignment: .bottom) {
            if !model.lastAction.isEmpty {
                Text(model.lastAction)
                    .font(.system(size: 11))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.thinMaterial))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.lastAction)
    }
}

// MARK: 通用

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("保留策略") {
                Picker("历史保留期", selection: $model.settings.retention) {
                    ForEach(ClipflowSettings.Retention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("超过保留期且未置顶的条目会在清理时删除。置顶条目永不自动删除。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                Picker("敏感内容（密码 / token）", selection: $model.settings.sensitiveTTL) {
                    ForEach(ClipflowSettings.SensitiveTTL.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("被识别为 token、密钥、密码的内容不会进入搜索索引；这里控制它们保留多久。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("容量上限") {
                // 数值放标题行 —— 之前放在滑块右侧，把滑块挤窄了，
                // 导致刻度行与滑块轨道宽度不同、刻度对不上实际位置。
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("存储上限")
                        Spacer()
                        if let st = model.stats {
                            Text("已用 \(ByteCountFormatter().string(fromByteCount: Int64(st.totalBytes)))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(SizeSteps.storageLabel(model.settings.maxStorageMB))
                            .font(.system(size: 12, design: .rounded)).bold().monospacedDigit()
                    }
                    SteppedSlider(steps: SizeSteps.storageMB,
                                  label: SizeSteps.storageLabel,
                                  value: $model.settings.maxStorageMB)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("条目数上限")
                        Spacer()
                        Text(SizeSteps.countLabel(model.settings.maxItems))
                            .font(.system(size: 12, design: .rounded)).bold().monospacedDigit()
                    }
                    SteppedSlider(steps: SizeSteps.itemCounts,
                                  label: SizeSteps.countLabel,
                                  value: $model.settings.maxItems)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("单条最大")
                        Spacer()
                        Text(SizeSteps.itemSizeLabel(model.settings.maxItemSizeMB))
                            .font(.system(size: 12, design: .rounded)).bold().monospacedDigit()
                    }
                    SteppedSlider(steps: SizeSteps.itemSizeMB,
                                  label: SizeSteps.itemSizeLabel,
                                  value: $model.settings.maxItemSizeMB)
                }

                Text("超出上限时从最久未使用的条目开始清理，置顶条目跳过。改动立即保存。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("快捷键") {
                HStack {
                    Text("唤出剪贴板面板")
                    Spacer()
                    HotKeyRecorderView(combo: $model.hotKey) { c in
                        model.hotKeyOK = AppDelegate.applyHotKeyGlobally(c)
                        model.syncHotKey()
                    }
                    .frame(width: 180, height: 24)
                    Button("恢复默认") {
                        _ = AppDelegate.resetHotKeyToDefault()
                        model.syncHotKey()
                        model.hotKeyOK = true
                    }
                }
                if !model.hotKeyOK {
                    Label("这个组合已被别的 App 占用，仍在使用 \(model.hotKey.display)。换一个试试。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Text("点一下按钮再按组合键。必须带至少一个修饰键（⌘ / ⌥ / ⌃ / ⇧），否则会劫走正常打字。"
                     + "录制期间全局快捷键会临时停用，取消或关窗都会自动恢复。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("行为") {
                Toggle("启动时捕获剪贴板已有内容", isOn: $model.settings.captureOnStart)
                Text("关掉的话，App 启动前复制的东西不会被记录。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: 历史

private struct HistoryTab: View {
    @ObservedObject var model: SettingsModel

    /// 列头点击排序。默认按「最近使用」倒序 —— 和面板一致。
    @State private var sortOrder: [KeyPathComparator<ClipItem>] = [
        KeyPathComparator(\ClipItem.usedSeq, order: .reverse)
    ]

    private var rows: [ClipItem] { model.items.sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            Table(rows, selection: $model.selected, sortOrder: $sortOrder) {
                TableColumn("内容", value: \.preview) { item in
                    HStack(spacing: 7) {
                        thumbOrIcon(item)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                                .lineLimit(1)
                            if item.pinned || item.sensitivity == .sensitive {
                                HStack(spacing: 5) {
                                    if item.pinned {
                                        Label("置顶", systemImage: "pin.fill")
                                    }
                                    if item.sensitivity == .sensitive {
                                        Label("敏感", systemImage: "lock.fill")
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.system(size: 9))
                                .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }.width(min: 240, ideal: 330)

                TableColumn("类型", value: \.kind) { item in
                    Text(item.kind.label).foregroundStyle(.secondary)
                }.width(56)

                TableColumn("来源", value: \.sourceLabel) { item in
                    Text(item.sourceLabel.isEmpty ? "—" : item.sourceLabel)
                        .lineLimit(1).foregroundStyle(.secondary)
                }.width(min: 90, ideal: 120)

                TableColumn("大小", value: \.byteSize) { item in
                    Text(ByteCountFormatter().string(fromByteCount: Int64(item.byteSize)))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }.width(74)

                TableColumn("用过", value: \.useCount) { item in
                    Text(item.useCount == 0 ? "—" : "\(item.useCount)")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }.width(46)

                TableColumn("时间", value: \.createdAt) { item in
                    Text(Self.stamp(item.createdAt))
                        .monospacedDigit().foregroundStyle(.secondary)
                }.width(112)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

            Divider()
            detailBar
        }
        .onAppear { model.refresh() }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("搜索内容…", text: $model.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            .frame(width: 230)

            Picker("", selection: $model.kindFilter) {
                Text("全部类型").tag(ClipKind?.none)
                Divider()
                ForEach(ClipKind.allCases, id: \.self) { k in
                    Text(k.label).tag(ClipKind?.some(k))
                }
            }
            .labelsHidden().frame(width: 108)

            Spacer()

            Button(role: .destructive) { model.deleteSelected() } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(model.selected.isEmpty)
            .help("删除选中的 \(model.selected.count) 条")

            Menu {
                Button("清空全部（保留置顶）") { model.deleteAll(keepPinned: true) }
                Button("清空全部（含置顶）", role: .destructive) { model.deleteAll(keepPinned: false) }
            } label: {
                Label("清空", systemImage: "trash.slash")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: 底部详情

    private var detailBar: some View {
        HStack(spacing: 10) {
            if let item = selectedItem {
                thumbOrIcon(item, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11)).lineLimit(2)
                    Text(model.formatSummary(for: item))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("\(model.items.count) 条")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("⌘ 点击多选 · ⇧ 点击连选 · 点列头排序")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.25))
    }

    private var selectedItem: ClipItem? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return model.items.first { $0.id == id }
    }

    // MARK: 小件

    @ViewBuilder
    private func thumbOrIcon(_ item: ClipItem, size: CGFloat = 20) -> some View {
        if let t = model.thumbnail(for: item) {
            Image(nsImage: t)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: size * 1.3, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        } else {
            Image(systemName: icon(for: item.kind))
                .font(.system(size: size * 0.6))
                .frame(width: size * 1.3, height: size)
                .foregroundStyle(.secondary)
        }
    }

    private func icon(for kind: ClipKind) -> String {
        switch kind {
        case .image: return "photo"
        case .fileRef: return "doc"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .richText: return "textformat"
        case .color: return "paintpalette"
        default: return "text.alignleft"
        }
    }

    /// 今天只显示时分，其余显示月日 —— 完整日期时间会被列宽截断，反而看不清
    static func stamp(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "今天 HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            f.dateFormat = "M月d日 HH:mm"
        } else { f.dateFormat = "yyyy/M/d HH:mm" }
        return f.string(from: d)
    }
}

// MARK: 存储

private struct StorageTab: View {
    @ObservedObject var model: SettingsModel

    private var f: ByteCountFormatter { ByteCountFormatter() }

    var body: some View {
        Form {
            if let s = model.stats {
                Section("当前占用") {
                    LabeledContent("条目总数", value: "\(s.items)")
                    LabeledContent("内容库", value: f.string(fromByteCount: Int64(s.contentDBBytes)))
                    LabeledContent("索引库", value: f.string(fromByteCount: Int64(s.indexDBBytes)))
                    LabeledContent("附件（图片等）",
                                   value: "\(s.blobCount) 个 · \(f.string(fromByteCount: Int64(s.blobBytes)))")
                    LabeledContent("合计") {
                        Text(f.string(fromByteCount: Int64(s.totalBytes))).bold()
                    }
                    if model.settings.maxStorageMB > 0 {
                        let used = Double(s.totalBytes)
                        let budget = Double(model.settings.maxStorageMB * 1024 * 1024)
                        VStack(alignment: .leading, spacing: 3) {
                            ProgressView(value: min(used / budget, 1.0))
                            Text("上限 \(model.settings.maxStorageMB) MB · 已用 \(Int(used / budget * 100))%")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("按类型分布") {
                ForEach(model.breakdown, id: \.kind) { row in
                    LabeledContent(row.kind.label,
                                   value: "\(row.count) 条 · \(f.string(fromByteCount: Int64(row.bytes)))")
                }
                if model.breakdown.isEmpty {
                    Text("暂无数据").foregroundStyle(.secondary)
                }
            }

            Section("维护") {
                HStack {
                    Button("按设置清理") { model.runCleanup() }
                    Button("只回收孤儿附件") { model.vacuumOnly() }
                    Spacer()
                    Button("在访达中显示") { model.revealDataFolder() }
                }
                Text("删除条目只删数据库行，附件文件要单独回收，否则磁盘只涨不降。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.store.paths.root.path)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}
