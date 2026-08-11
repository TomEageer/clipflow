import Testing
import AppKit
import Foundation
@testable import ClipflowCapture

/// 用私有剪贴板，绝不碰 `NSPasteboard.general` —— 测试跑起来不该把用户
/// 正在用的剪贴板洗掉。
private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.tomeageer.clipflow.test.\(UUID().uuidString)"))
}

@Suite("剪贴板变更抑制")
struct PasteboardSuppressionTests {

    private func write(_ s: String, to pb: NSPasteboard) -> Int {
        pb.clearContents()
        pb.setString(s, forType: .string)
        return pb.changeCount
    }

    @Test("自己写回剪贴板的那一次不该被当成新内容")
    func ownEchoSuppressed() {
        let pb = makePasteboard()
        let w = PasteboardWatcher(pasteboard: pb)
        w.suppress(changeCount: write("我们自己粘出去的内容", to: pb))
        #expect(w.hasChanged() == false, "自己写回的内容被当成了新复制 —— 会形成回声")
    }

    /// ⚠️ 回归测试：这条挂过。
    ///
    /// 旧实现是 `for d in 0...2 { insert(c + d) }`，而 `c` 已经是自己那次写入的计数，
    /// `c+1` / `c+2` 是**用户接下来的两次复制** —— 于是从面板粘贴一次之后，
    /// 用户再复制两次全被静默吞掉，内容永远进不了历史。
    /// 实测复现过：粘贴后连续复制 A/B/C/D，只有 C、D 入库。
    @Test("抑制自己那一次后，用户随后的每一次复制都必须进来")
    func laterUserCopiesNotSwallowed() {
        let pb = makePasteboard()
        let w = PasteboardWatcher(pasteboard: pb)

        w.suppress(changeCount: write("我们自己粘出去的内容", to: pb))
        #expect(w.hasChanged() == false)

        for (i, text) in ["用户复制 A", "用户复制 B", "用户复制 C"].enumerated() {
            _ = write(text, to: pb)
            #expect(w.hasChanged() == true,
                    "粘贴后第 \(i + 1) 次用户复制被吞了 —— 抑制范围又放宽了")
        }
    }

    @Test("没变化时不该报变更")
    func noChangeNoReport() {
        let pb = makePasteboard()
        _ = write("初始内容", to: pb)
        let w = PasteboardWatcher(pasteboard: pb)
        #expect(w.hasChanged() == false)
        #expect(w.hasChanged() == false)
    }

    @Test("连续多次自己写入，每次都精确抑制自己")
    func repeatedOwnWrites() {
        let pb = makePasteboard()
        let w = PasteboardWatcher(pasteboard: pb)
        for i in 0..<5 {
            w.suppress(changeCount: write("自己第 \(i) 次", to: pb))
            #expect(w.hasChanged() == false)
            _ = write("用户第 \(i) 次", to: pb)
            #expect(w.hasChanged() == true, "第 \(i) 轮用户复制被吞")
        }
    }

    /// 抑制集合不能无限长 —— 抑制值一直没被消费掉时（写完又被别人立刻改写）会堆积
    @Test("抑制集合有上界")
    func suppressionSetBounded() {
        let pb = makePasteboard()
        let w = PasteboardWatcher(pasteboard: pb)
        for i in 0..<200 { w.suppress(changeCount: 1_000_000 + i) }
        // 堆积被裁掉后，正常的用户复制仍然要能进来
        _ = write("用户复制", to: pb)
        #expect(w.hasChanged() == true)
    }
}
