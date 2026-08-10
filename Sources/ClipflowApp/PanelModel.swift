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
            items = q.isEmpty ? try store.recent(limit: 200) : try store.search(q, limit: 200)
            total = try store.count()
            if let keepID, let idx = items.firstIndex(where: { $0.id == keepID }) {
                selection = idx
            } else {
                selection = 0
            }
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

    func select(_ i: Int) {
        guard i >= 0, i < items.count, i != selection else { return }
        selection = i
    }

    func handleKey(_ action: KeyAction) -> Bool {
        switch action {
        case .up:
            // 到顶再往上就回到最后一条，循环比"卡住不动"顺手
            selection = selection > 0 ? selection - 1 : max(0, items.count - 1)
            return true
        case .down:
            selection = selection < items.count - 1 ? selection + 1 : 0
            return true
        case .confirm:  confirm(); return true
        case .cancel:   onClose?(); return true
        case .pick(let i):
            guard i < items.count else { return true }
            selection = i; confirm(); return true
        case .pin:      togglePin(); return true
        case .delete:   deleteSelected(); return true
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
    /// 先关面板再粘贴：键盘焦点在面板上，不先关的话合成的 ⌘V 会打到面板自己身上。
    func confirm() {
        guard let item = selectedItem, let id = item.id else { return }
        onClose?()

        // 粘过的内容冒到顶部 —— 下次唤出就在手边
        try? store.touch(itemID: id)

        do {
            let reps = try store.representations(of: id)
            var payload: [(uti: String, data: Data)] = []
            for r in reps {
                if let d = try store.data(of: r), !d.isEmpty { payload.append((r.uti, d)) }
            }
            // 等面板淡出 + 前台 App 恢复 key 状态。80ms 是淡出动画(80ms)之后的一帧。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                guard let self else { return }
                do {
                    try self.paster.paste(representations: payload)
                } catch {
                    self.paster.copyOnly(representations: payload)
                    self.onError?("\(error)")
                }
            }
        } catch {
            onError?("读取失败：\(error)")
        }
    }
}
