import AppKit
import SwiftUI

/// 就地编辑用的小输入框（分组改名、条目命名共用）。
///
/// ⚠️ 键盘处理必须走 `control(_:textView:doCommandBy:)`，**不能 override keyDown**：
/// NSTextField 获得焦点时真正的 first responder 是它的 field editor，
/// text field 自己的 keyDown 根本收不到（Esc 关不掉面板那次就是这么来的）。
///
/// ⚠️ **必须有"失焦即退出"这条出路。** 只认回车和 Esc 的话，用户点了别处就把这个框
/// 永久留在界面上了 —— 分组胶囊卡在输入框状态下不来，实测发生过。
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 11
    /// 回车 / 失焦时调用
    var onCommit: () -> Void
    /// Esc 时调用
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: fontSize)
        tf.delegate = context.coordinator
        tf.stringValue = text
        tf.lineBreakMode = .byTruncatingTail
        // 出现即聚焦。同步调用时视图还没进窗口，推到下一轮。
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ v: NSTextField, context: Context) {
        context.coordinator.parent = self
        if v.font?.pointSize != fontSize { v.font = .systemFont(ofSize: fontSize) }
        if v.stringValue != text { v.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        /// Esc 走的是取消路径，此时的失焦不能再当成提交
        private var cancelled = false

        init(_ p: InlineTextField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !cancelled else { cancelled = false; return }
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelled = true
                parent.onCancel(); return true
            default:
                return false
            }
        }
    }
}
