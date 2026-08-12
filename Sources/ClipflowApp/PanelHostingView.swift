import AppKit
import SwiftUI

/// 面板内容的宿主视图。
///
/// ⚠️ **必须关掉 `mouseDownCanMoveWindow`。**
///
/// 面板没有标题栏，靠 `isMovableByWindowBackground` 拖背景挪窗口。但 AppKit 是问
/// **鼠标下那个 NSView** 要不要接管拖拽的，而 SwiftUI 的内容全画在
/// `NSHostingView` 一个视图的图层里 —— 于是不管鼠标在面板哪儿按下、包括按在
/// 一个挂了 `.draggable` 的胶囊上，AppKit 都先把它当成"拖窗口"。
///
/// 实测：想拖分组胶囊排序，结果整个面板跟着鼠标跑，胶囊纹丝不动。
///
/// 所以这里统一关掉，再用 `WindowDragHandle` 把"可以拖窗口"的区域显式还给顶部一条。
/// 这样窗口照样能拖，而面板内部的拖拽（分隔条、胶囊排序）也都能正常工作。
final class PanelHostingView<Content: View>: NSHostingView<Content> {

    override var mouseDownCanMoveWindow: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }
}

/// 显式的「可以从这里拖动窗口」区域。铺在搜索栏那一行的背景上。
///
/// 宿主视图关掉窗口拖拽之后，得有个地方把这个能力还回来 ——
/// 否则面板就彻底挪不动了（它没有标题栏可抓）。
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
