import AppKit
import SwiftUI
import ClipflowCore
import ClipflowCapture

@MainActor
final class PanelModel: ObservableObject {

    @Published var query: String = "" { didSet { reload() } }
    @Published private(set) var items: [ClipItem] = []
    @Published var selection: Int = 0
    @Published private(set) var total: Int = 0

    private let store: ClipflowStore
    private let paster: Paster
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?

    init(store: ClipflowStore, paster: Paster) {
        self.store = store
        self.paster = paster
    }

    func reload() {
        do {
            items = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.recent(limit: 200)
                : try store.search(query, limit: 200)
            total = try store.count()
            selection = 0
        } catch {
            items = []
        }
    }

    func select(_ i: Int) {
        guard i >= 0, i < items.count else { return }
        selection = i
    }

    func handleKey(_ action: KeyAction) -> Bool {
        switch action {
        case .up:
            selection = max(0, selection - 1); return true
        case .down:
            selection = min(max(0, items.count - 1), selection + 1); return true
        case .confirm:
            confirm(); return true
        case .cancel:
            onClose?(); return true
        case .pick(let i):
            guard i < items.count else { return true }
            selection = i; confirm(); return true
        }
    }

    /// 选中并粘贴。
    ///
    /// 顺序很关键：**先关面板，再粘贴**。面板虽然是 nonactivating 不抢焦点，
    /// 但键盘输入在它上面；不先关，合成的 Cmd+V 会打到面板自己身上。
    func confirm() {
        guard selection < items.count, let id = items[selection].id else { return }
        onClose?()

        do {
            let reps = try store.representations(of: id)
            var payload: [(uti: String, data: Data)] = []
            for r in reps {
                if let d = try store.data(of: r), !d.isEmpty {
                    payload.append((r.uti, d))
                }
            }
            // 让前台 App 有一帧时间恢复 key 状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                do {
                    try self.paster.paste(representations: payload)
                } catch {
                    // 无权限/安全输入 → 降级为「已放进剪贴板，请手动 Cmd+V」，绝不静默失败
                    self.paster.copyOnly(representations: payload)
                    self.onError?("\(error) —— 内容已放入剪贴板，请手动按 ⌘V")
                }
            }
        } catch {
            onError?("读取失败：\(error)")
        }
    }
}
