import Foundation
import CoreGraphics

/// 面板相对鼠标的摆放：位置 + 尺寸 + 是否镜像。
///
/// **核心取舍：贴边时优先缩尺寸，而不是翻到另一边。**
///
/// 面板可以被拉到 1000pt 以上，而原来的规则是「右边放不下就开到左边」。
/// 结果是鼠标只要在屏幕右半区就会触发镜像 —— 而镜像会把列表和预览**左右对调**，
/// 每次唤出布局都可能不一样，比面板窄一点难受得多。
///
/// 所以：右边放得下就用完整尺寸；放不下但还够摆一个能用的面板，就**把宽度缩到可用空间**、
/// 保持不镜像；只有缩到连 `shrinkFloorRatio` 都保不住时，才认账翻到另一边。
/// 高度同理（纵向没有镜像问题，但缩比翻上去更少打断视线）。
///
/// 和 `SplitLayout` 一样放在 Core：这段逻辑的价值全在边界上，
/// 写进 `NSPanel` 子类就只能靠把鼠标挪到屏幕角落一次次试。
public enum PanelPlacement {

    /// 缩到偏好尺寸的多少以下就不值得再缩了 —— 宁可翻到另一边保持完整。
    /// 0.6 是"明显变小但仍然好用"与"还不如翻过去"的分界。
    public static let shrinkFloorRatio: CGFloat = 0.6

    public struct Result: Equatable, Sendable {
        public var frame: CGRect
        /// true = 面板开在鼠标左侧，内部列表与预览要左右对调
        public var mirrored: Bool
    }

    public static func place(mouse: CGPoint,
                             preferred: CGSize,
                             minSize: CGSize,
                             visible: CGRect,
                             gap: CGFloat = 8) -> Result {

        // 屏幕本身就比面板小的话先按屏幕收一遍，后面的判断才有意义
        let wantW = max(1, min(preferred.width, visible.width - 2 * gap))
        let wantH = max(1, min(preferred.height, visible.height - 2 * gap))
        let minW = min(minSize.width, wantW)
        let minH = min(minSize.height, wantH)
        let floorW = max(minW, wantW * shrinkFloorRatio)
        let floorH = max(minH, wantH * shrinkFloorRatio)

        // MARK: 横向 —— 默认往右开
        let roomRight = visible.maxX - mouse.x - gap
        let roomLeft  = mouse.x - gap - visible.minX
        let width: CGFloat
        let mirrored: Bool
        if roomRight >= wantW {
            width = wantW; mirrored = false
        } else if roomRight >= floorW {
            width = roomRight; mirrored = false          // 缩，不翻
        } else if roomLeft >= minW {
            width = min(wantW, roomLeft); mirrored = true
        } else {
            // 两边都塞不下：挑空间大的那边，宽度按下限兜底（后面再钳进屏幕）
            mirrored = roomLeft > roomRight
            width = max(minW, mirrored ? roomLeft : roomRight)
        }

        // MARK: 纵向 —— 默认往下开（origin 在鼠标下方 gap 处向下延伸）
        let roomBelow = mouse.y - gap - visible.minY
        let roomAbove = visible.maxY - mouse.y - gap
        let height: CGFloat
        let below: Bool
        if roomBelow >= wantH {
            height = wantH; below = true
        } else if roomBelow >= floorH {
            height = roomBelow; below = true
        } else if roomAbove >= minH {
            height = min(wantH, roomAbove); below = false
        } else {
            below = roomBelow > roomAbove
            height = max(minH, below ? roomBelow : roomAbove)
        }

        var origin = CGPoint(x: mirrored ? mouse.x - gap - width : mouse.x + gap,
                             y: below ? mouse.y - gap - height : mouse.y + gap)
        // 兜底钳制：上面每条分支都可能因为屏幕过小而溢出
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - height))

        return Result(frame: CGRect(origin: origin,
                                    size: CGSize(width: width, height: height)),
                      mirrored: mirrored)
    }
}
