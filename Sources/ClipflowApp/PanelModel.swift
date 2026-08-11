import AppKit
import SwiftUI
import ClipflowCore
import ClipflowCapture

@MainActor
final class PanelModel: ObservableObject {

    @Published var query: String = "" { didSet { scheduleReload() } }
    @Published private(set) var items: [ClipItem] = []
    @Published var selection: Int = 0
    @Published private(set) var total: Int = 0
    /// 面板开在鼠标左侧时为 true：列表与预览左右对调，让可点击的列表贴着鼠标。
    /// 只镜像左右，**不做上下反转** —— 列表倒序违反阅读直觉。
    @Published var mirrored: Bool = false
    /// 界面缩放系数，从设置读；改了立刻反映到面板
    @Published var uiScale: Double = ClipflowSettings.load().uiScale
    @Published var developerMode: Bool = ClipflowSettings.load().developerMode
    /// 变换菜单是否展开
    @Published var showTransforms = false

    // MARK: 分栏

    /// 列表占面板宽度的比例。存比例而非像素：面板本身可自由拉伸，
    /// 存死宽度的话把窗口拉宽后增量全压给预览，列表永远是原来那么宽。
    @Published private(set) var splitRatio: Double = ClipflowSettings.load().splitRatio

    /// 由比例算出列表实际宽度。**夹紧规则在 Core 的 SplitLayout 里，有测试守着。**
    func listWidth(total: CGFloat, theme t: Theme) -> CGFloat {
        CGFloat(SplitLayout.listWidth(total: Double(total),
                                      ratio: splitRatio,
                                      minList: Double(t.minListWidth),
                                      minPreview: Double(t.minPreviewWidth),
                                      splitter: Double(t.splitterWidth)))
    }

    /// 拖分隔条。`width` 是拖到的目标列表宽度（镜像时调用方已翻好符号）。
    func setListWidth(_ width: CGFloat, total: CGFloat, theme t: Theme) {
        guard let r = SplitLayout.ratio(forListWidth: Double(width),
                                        total: Double(total),
                                        minList: Double(t.minListWidth),
                                        minPreview: Double(t.minPreviewWidth),
                                        splitter: Double(t.splitterWidth)) else { return }
        splitRatio = r
    }

    /// 松手才写盘。拖动过程中每帧存一次 UserDefaults 纯属浪费。
    func persistSplit() {
        var s = ClipflowSettings.load()
        s.splitRatio = splitRatio
        s.save()
    }

    let transformers = TransformerRegistry.standard()

    /// 选中条目可用的变换。不适用的不显示 —— 列一堆点了没反应的动作最恼人。
    ///
    /// ⚠️ **必须缓存，不能写成 computed property。**
    /// 判定要跑 `JSONDetector.looksLikeJSON`（真解析一遍）和一串字符串扫描，
    /// 而 footer 和预览头每次 body 求值都会读它 —— 之前那版等于每帧解析一次 JSON。
    /// 改成随选中项变化时算一次。
    @Published private(set) var availableTransforms: [Transformer] = []

    /// 选中项是不是一段合法 JSON。预览头的徽章与「格式化」开关据此显示。
    @Published private(set) var selectedIsJSON = false
    /// 预览是否以格式化形式展示 JSON。开发者模式下默认开（省一次点击），
    /// 但**任何人都能点头部那个开关切回原文** —— 不再是藏在设置里的隐形功能。
    @Published var prettyJSON: Bool = ClipflowSettings.load().developerMode

    private func refreshTransforms() {
        guard let item = selectedItem else {
            availableTransforms = []; selectedIsJSON = false; return
        }
        let text = fullText(for: item)
        guard !text.isEmpty, text.count < 500_000 else {
            availableTransforms = []; selectedIsJSON = false; return
        }
        availableTransforms = transformers.applicable(to: text, developerMode: developerMode)
        selectedIsJSON = JSONDetector.looksLikeJSON(text)
    }

    /// 预览正文。识别为 JSON 且开着格式化时给格式化版本。
    func displayText(for item: ClipItem) -> (text: String, isFormattedJSON: Bool) {
        let raw = fullText(for: item)
        guard prettyJSON, selectedIsJSON,
              let pretty = JSONDetector.pretty(raw), pretty != raw else {
            return (raw, false)
        }
        return (pretty, true)
    }

    /// 应用变换并粘贴。变换只影响这一次粘贴，**不改库里的原始内容** ——
    /// 保真是本项目的地基，原始数据不能被就地改写。
    func applyTransform(_ t: Transformer) {
        guard let item = selectedItem, let id = item.id else { return }
        let source = fullText(for: item)
        guard let out = try? t.apply(to: source) else {
            onError?("变换失败：\(t.title)")
            return
        }
        showTransforms = false
        try? store.touch(itemID: id)
        do {
            try paster.stage(representations: [("public.utf8-plain-text", Data(out.utf8), 0)])
            onPaste?()
        } catch {
            onError?("\(error)")
        }
    }

    /// 当前分类。切换要靠点击，不自动跳 —— 自动跳会让人找不到刚才那条。
    @Published var category: PanelCategory = .all { didSet { reload() } }
    /// 各分类条目数，标签上显示
    @Published private(set) var counts: [ClipKind: Int] = [:]

    private let store: ClipflowStore
    private let paster: Paster
    /// 缩略图内存缓存。磁盘缓存在 ThumbnailStore 里，这层避免滚动时反复读盘。
    private var thumbCache: [String: NSImage] = [:]
    private var largeCache: [String: NSImage] = [:]
    private var textCache: [Int64: String] = [:]
    private var searchDebounce: Task<Void, Never>?

    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?

    init(store: ClipflowStore, paster: Paster) {
        self.store = store
        self.paster = paster
    }

    var selectedItem: ClipItem? {
        selection < items.count ? items[selection] : nil
    }
    var selectedIsPinned: Bool { selectedItem?.pinned ?? false }

    // MARK: 加载

    /// 输入时防抖 80ms。每敲一个字就查一次数据库会让光标发涩，
    /// 尤其中文输入法在组字阶段会连发多次。
    private func scheduleReload() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        do {
            let q = query.trimmingCharacters(in: .whitespaces)
            // 记住当前选中的条目 id，刷新后尽量停在原处 —— 后台捕获到新内容时
            // 选中项被重置回第一条，是很打断人的
            let keepID = selectedItem?.id
            let kinds = category.kinds
            if q.isEmpty {
                items = try store.recent(limit: 200, kinds: kinds)
            } else {
                // 搜索结果再按分类筛。搜索已限量，客户端筛的代价可忽略。
                let hits = try store.search(q, limit: 400)
                items = kinds.map { k in hits.filter { k.contains($0.kind) } } ?? hits
                if items.count > 200 { items = Array(items.prefix(200)) }
            }
            counts = (try? store.countsByKind()) ?? [:]
            total = try store.count()
            if let keepID, let idx = items.firstIndex(where: { $0.id == keepID }) {
                selection = idx
            } else {
                selection = 0
            }
            showTransforms = false
            refreshTransforms()
            if thumbCache.count > 300 { thumbCache.removeAll(keepingCapacity: true) }
            if largeCache.count > 12 { largeCache.removeAll(keepingCapacity: true) }
            if textCache.count > 200 { textCache.removeAll(keepingCapacity: true) }
        } catch {
            items = []
        }
    }

    // MARK: 预览

    func thumbnail(for item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let c = thumbCache[item.contentHash] { return c }
        guard let png = store.thumbnail(for: item), let img = NSImage(data: png) else { return nil }
        thumbCache[item.contentHash] = img
        return img
    }

    /// 预览面板用的大图。仍走缩略图管线（600px），**不解码原图** ——
    /// 一张 12.8MB 的 TIFF 直接塞进 SwiftUI 会明显卡顿。
    func largePreview(for item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let c = largeCache[item.contentHash] { return c }
        guard let png = store.thumbnail(for: item, size: 600), let img = NSImage(data: png) else { return nil }
        largeCache[item.contentHash] = img
        return img
    }

    /// 预览面板用的全文。preview 字段是截断过的，这里取真正的完整内容。
    func fullText(for item: ClipItem) -> String {
        guard let id = item.id else { return item.preview }
        if let c = textCache[id] { return c }
        var text = item.preview
        if let reps = try? store.representations(of: id),
           let plain = reps.first(where: { $0.uti == "public.utf8-plain-text" }),
           let d = try? store.data(of: plain), let s = String(data: d, encoding: .utf8) {
            text = s
        }
        // 别把 10MB 文本塞进视图
        if text.count > 20_000 { text = String(text.prefix(20_000)) + "\n\n…（已截断）" }
        textCache[id] = text
        return text
    }

    /// 图片条目的 OCR 文本，用于预览面板展示"图里有什么字"
    func ocrText(for item: ClipItem) -> String? {
        guard item.kind == .image, let id = item.id else { return nil }
        guard let text = (try? store.ocrText(for: id)) ?? nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 底部那行：这条到底存了哪些格式、各多大。保真度是本项目的卖点，得看得见。
    func formatSummary(for item: ClipItem) -> String {
        guard let id = item.id, let reps = try? store.representations(of: id) else { return "" }
        let f = ByteCountFormatter()
        return reps
            .sorted { $0.byteSize > $1.byteSize }
            .prefix(4)
            .map { "\($0.uti.replacingOccurrences(of: "public.", with: "")) \(f.string(fromByteCount: Int64($0.byteSize)))" }
            .joined(separator: "  ")
    }

    // MARK: 交互

    /// 选中项是被谁改的。**只有键盘驱动的改变才允许自动滚动。**
    ///
    /// 鼠标划过即选中 + 选中即滚动 = 反馈循环：
    /// 划过 → 选中 → 滚动 → 列表位移 → 鼠标下换了一行 → 又选中 → 又滚动。
    /// 列表会追着鼠标跑，非常难受。
    enum SelectionSource { case mouse, keyboard }

    /// 递增计数器。只在键盘驱动时 +1，视图据此决定要不要滚动。
    @Published private(set) var scrollToken: Int = 0

    func select(_ i: Int, from source: SelectionSource = .mouse) {
        guard i >= 0, i < items.count, i != selection else { return }
        selection = i
        showTransforms = false
        refreshTransforms()
        if source == .keyboard { scrollToken += 1 }
    }

    /// 设置窗口改过的东西，下次唤出面板时生效。
    func applySettings(_ s: ClipflowSettings) {
        uiScale = s.uiScale
        if developerMode != s.developerMode {
            developerMode = s.developerMode
            prettyJSON = s.developerMode
            refreshTransforms()
        }
        splitRatio = s.splitRatio
    }

    func handleKey(_ action: KeyAction) -> Bool {
        switch action {
        case .up:
            // 到顶再往上就回到最后一条，循环比"卡住不动"顺手
            select(selection > 0 ? selection - 1 : max(0, items.count - 1), from: .keyboard)
            return true
        case .down:
            select(selection < items.count - 1 ? selection + 1 : 0, from: .keyboard)
            return true
        case .confirm:  confirm(); return true
        case .cancel:
            // 变换菜单开着时，esc 先关它，再按才关面板 —— 逐层退出符合直觉
            if showTransforms { showTransforms = false } else { onClose?() }
            return true
        case .pick(let i):
            guard i < items.count else { return true }
            select(i, from: .keyboard); confirm(); return true
        case .pin:      togglePin(); return true
        case .delete:   deleteSelected(); return true
        case .transform:
            guard !availableTransforms.isEmpty else { return true }
            showTransforms.toggle(); return true
        }
    }

    private func togglePin() {
        guard let item = selectedItem, let id = item.id else { return }
        try? store.setPinned(!item.pinned, itemID: id)
        reload()
    }

    private func deleteSelected() {
        guard let item = selectedItem, let id = item.id else { return }
        let keep = selection
        try? store.delete(itemID: id)
        reload()
        // 删除后停在同一位置（而不是跳回顶部），方便连续删
        selection = min(keep, max(0, items.count - 1))
    }

    /// 选中并粘贴。
    ///
    /// **时序按"感知延迟最小"排**，每一步的位置都有理由：
    ///
    /// 1. 先把内容写进剪贴板 —— 这一步最快且不依赖任何等待，先做掉。
    ///    做完这一步，即使后面全失败，用户手动 ⌘V 也能拿到东西。
    /// 2. 立刻关面板 —— 视觉反馈要在第一时间给出，不能等粘贴完成。
    /// 3. 切回原 App，**轮询**等它真正到前台（不是固定 sleep）。
    /// 4. 合成 ⌘V。
    ///
    /// 键盘焦点在面板上，必须先关面板，否则合成的 ⌘V 会打到面板自己身上。
    func confirm() {
        guard let item = selectedItem, let id = item.id else { return }

        // ① 先取内容并写进剪贴板 —— 放在最前面，因为它最快且是兜底
        var payload: [(uti: String, data: Data, itemIndex: Int)] = []
        do {
            for r in try store.representations(of: id) {
                if let d = try store.data(of: r), !d.isEmpty { payload.append((r.uti, d, r.itemIndex)) }
            }
            try paster.stage(representations: payload)
        } catch {
            onError?("读取失败：\(error)")
            return
        }

        // 粘过的内容冒到顶部 —— 下次唤出就在手边
        try? store.touch(itemID: id)

        // ② 立刻关面板并触发"切回原 App + 粘贴"
        onPaste?()
    }

    /// 由 AppDelegate 接管：关面板 → 切回原 App → 轮询就绪 → 合成 ⌘V。
    /// 放在 AppDelegate 是因为只有它知道"原来那个 App"是谁。
    var onPaste: (() -> Void)?

    func reportPasteFailure(_ message: String) {
        onError?(message + "\n\n内容已在剪贴板里，直接按 ⌘V 即可。")
    }
}
