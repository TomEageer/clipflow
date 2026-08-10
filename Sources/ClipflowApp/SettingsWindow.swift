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

    func show(tab: Int? = nil) {
        if let tab { model.selectedTab = tab }
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
    @Published var sourceFilter: String? { didSet { refreshList() } }

    var hasFilter: Bool { kindFilter != nil || sourceFilter != nil }

    func clearFilters() {
        kindFilter = nil
        sourceFilter = nil
    }
    @Published var query: String = "" { didSet { refreshList() } }
    @Published var selected: Set<ClipItem.ID> = []
    @Published var lastAction: String = ""
    @Published var selectedTab: Int = 0
    /// 显示**实际生效**的组合，不是"保存过的那个"。注册失败时两者会不一致，
    /// 显示保存值等于界面在骗人。
    @Published var hotKey: HotKeyCombo = AppDelegate.currentActiveCombo() ?? HotKeyCombo.load()
    @Published var hotKeyOK: Bool = true
    @Published var updateState = UpdateState()
    @Published private(set) var ocrStats: (done: Int, pending: Int, skipped: Int)?

    func checkForUpdates() {
        updateState = .checking()
        Task { @MainActor in
            do {
                let r = try await Updater.check()
                updateState = r.hasUpdate ? .available(r.latest) : .upToDate(r.current)
            } catch {
                updateState = .failed(error)
            }
        }
    }

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
        ocrStats = try? store.ocrStats()
        stats = try? store.stats()
    }

    func refreshList() {
        items = (try? store.browse(sort: .recentlyUsed, kind: kindFilter,
                                   source: sourceFilter, query: query)) ?? []
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
        TabView(selection: $model.selectedTab) {
            GeneralTab(model: model).tabItem { Label("通用", systemImage: "gearshape") }.tag(0)
            HistoryTab(model: model).tabItem { Label("历史记录", systemImage: "clock.arrow.circlepath") }.tag(1)
            StorageTab(model: model).tabItem { Label("存储", systemImage: "internaldrive") }.tag(2)
            AboutTab().tabItem { Label("关于", systemImage: "info.circle") }.tag(3)
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
                LabeledContent("历史保留期") {
                    Picker("", selection: $model.settings.retention) {
                        ForEach(ClipflowSettings.Retention.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }.labelsHidden().frame(width: 130)
                }
                LabeledContent("敏感内容") {
                    Picker("", selection: $model.settings.sensitiveTTL) {
                        ForEach(ClipflowSettings.SensitiveTTL.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }.labelsHidden().frame(width: 130)
                }
                Text("超过保留期且未置顶的条目会在清理时删除，置顶条目永不自动删除。"
                     + "被识别为 token / 密钥 / 密码的内容不会进入搜索索引。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("容量上限") {
                LabeledContent {
                    SteppedSlider(steps: SizeSteps.storageMB,
                                  label: SizeSteps.storageLabel,
                                  value: $model.settings.maxStorageMB)
                } label: {
                    Text("存储上限")
                    if let st = model.stats {
                        Text("已用 \(ByteCountFormatter().string(fromByteCount: Int64(st.totalBytes)))")
                    }
                }

                LabeledContent("条目数上限") {
                    SteppedSlider(steps: SizeSteps.itemCounts,
                                  label: SizeSteps.countLabel,
                                  value: $model.settings.maxItems)
                }

                LabeledContent("单条最大") {
                    SteppedSlider(steps: SizeSteps.itemSizeMB,
                                  label: SizeSteps.itemSizeLabel,
                                  value: $model.settings.maxItemSizeMB)
                }

                Text("超出上限时从最久未使用的条目开始清理，置顶条目跳过。改动立即保存。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("快捷键") {
                LabeledContent("唤出剪贴板面板") {
                    HStack(spacing: 6) {
                        HotKeyRecorderView(combo: $model.hotKey) { c in
                            model.hotKeyOK = AppDelegate.applyHotKeyGlobally(c)
                            model.syncHotKey()
                        }
                        .frame(width: 132, height: 22)
                        Button("恢复默认") {
                            _ = AppDelegate.resetHotKeyToDefault()
                            model.syncHotKey()
                            model.hotKeyOK = true
                        }
                        .controlSize(.small)
                    }
                }
                if !model.hotKeyOK {
                    Label("这个组合已被别的 App 占用，仍在使用 \(model.hotKey.display)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Text("点一下按钮再按组合键，必须带至少一个修饰键。录制期间全局快捷键临时停用，取消或关窗会自动恢复。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("图片文字识别") {
                Toggle("识别截图里的文字，使其可被搜索", isOn: $model.settings.enableOCR)
                if let o = model.ocrStats {
                    LabeledContent("已识别") {
                        Text("\(o.done) 张 · 待处理 \(o.pending) · 无文字或跳过 \(o.skipped)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("完全在本机运行（Apple Vision），不联网。低电量模式下自动暂停。"
                     + "识别到密码 / 密钥类文字的图片，结果不会进入搜索索引。改动后重启生效。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("行为") {
                Toggle("启动时捕获剪贴板已有内容", isOn: $model.settings.captureOnStart)
                Toggle("启动时自动检查更新", isOn: $model.settings.autoCheckUpdates)
                LabeledContent("软件更新") {
                    HStack(spacing: 8) {
                        if model.updateState.isChecking { ProgressView().controlSize(.small) }
                        Text(model.updateState.message)
                            .font(.system(size: 11))
                            .foregroundStyle(model.updateState.hasUpdate ? Color.accentColor : .secondary)
                        Button(model.updateState.hasUpdate ? "前往下载" : "检查更新") {
                            if model.updateState.hasUpdate { Updater.openReleasePage() }
                            else { model.checkForUpdates() }
                        }
                        .controlSize(.small)
                    }
                }
                Text("检查更新会向 GitHub 请求一次最新版本号，这是本应用唯一的网络请求，且只在你触发或勾选自动检查时发生。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
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

                // 点单元格即按该值筛选 —— 比另开一个下拉框直观，也少一个控件
                TableColumn("类型", value: \.kind) { item in
                    FilterCell(text: item.kind.label,
                               active: model.kindFilter == item.kind) {
                        model.kindFilter = (model.kindFilter == item.kind) ? nil : item.kind
                    }
                }.width(62)

                TableColumn("来源", value: \.sourceLabel) { item in
                    if item.sourceLabel.isEmpty {
                        Text("—").foregroundStyle(.tertiary)
                    } else {
                        FilterCell(text: item.sourceLabel,
                                   active: model.sourceFilter == item.sourceLabel) {
                            model.sourceFilter =
                                (model.sourceFilter == item.sourceLabel) ? nil : item.sourceLabel
                        }
                    }
                }.width(min: 96, ideal: 130)

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

            // 当前生效的筛选做成可一键移除的标签。
            // 不做下拉框：筛选是从表格里点出来的，用户的注意力就在表格上。
            if let k = model.kindFilter {
                FilterChip(icon: "tag", text: k.label) { model.kindFilter = nil }
            }
            if let src = model.sourceFilter {
                FilterChip(icon: "app.badge", text: src) { model.sourceFilter = nil }
            }
            if model.hasFilter {
                Button("清除筛选") { model.clearFilters() }
                    .buttonStyle(.link).font(.system(size: 11))
            }

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
                Text(Self.hint)
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

    static let hint = "点类型或来源即可筛选 · 点列头排序 · ⌘ 点击多选"

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

// MARK: - 可点击筛选的单元格与筛选标签

/// 表格里可点击的值。点一下按该值筛选，再点一下取消。
/// 平时看着就是普通文字，鼠标移上去才显出可点击 —— 不打扰阅读。
private struct FilterCell: View {
    let text: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Color.accentColor.opacity(0.15)
                                     : (hovering ? Color.primary.opacity(0.08) : .clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(active ? "点击取消筛选" : "点击只看「\(text)」")
    }
}

/// 工具栏上的筛选标签，带 × 一键移除
private struct FilterChip: View {
    let icon: String
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .foregroundStyle(Color.accentColor)
    }
}
