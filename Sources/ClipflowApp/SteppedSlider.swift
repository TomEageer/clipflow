import AppKit
import SwiftUI

/// 分档滑块。
///
/// ## 两个坑，都踩过
///
/// 1. **不能用 TextField**：数字输入框要按回车或失焦才提交，用户改完看着变了、
///    其实没写进设置 —— 「设置不了存储上限」就是这么来的。滑块每动一格立即写入。
///
/// 2. **刻度必须由 slider 自己画**。早期版本把刻度文字放在一个独立的 HStack 里，
///    而 slider 右边还被数值列挤掉一截 —— 两者宽度不同，刻度和实际位置对不上。
///    现在用 AppKit `NSSlider` 的原生 tick marks，位置由系统按档位算，不可能错位。
struct SteppedSlider<T: Equatable & BinaryInteger>: View {

    let steps: [T]
    let label: (T) -> String
    @Binding var value: T
    /// 滑块宽度。**刻意收窄**：铺满整行的滑块看着松垮，
    /// 而且档位就那么几个，长轨道对定位毫无帮助。
    var width: CGFloat = 168

    /// 当前值不在档位里时（比如老版本用输入框设过 700MB），落到**最接近**的一档。
    /// 直接 `firstIndex ?? 0` 会静默显示成最小档，用户没动过却看到值变了。
    private var nearestIndex: Int {
        if let exact = steps.firstIndex(of: value) { return exact }
        let candidates = steps.enumerated().filter { $0.element != 0 }  // 0 = 不限制，不比距离
        guard let best = candidates.min(by: {
            abs(Int($0.element) - Int(value)) < abs(Int($1.element) - Int(value))
        }) else { return 0 }
        return best.offset
    }

    var body: some View {
        HStack(spacing: 10) {
            TickedSlider(
                count: steps.count,
                index: Binding(
                    get: { nearestIndex },
                    set: { i in
                        guard steps.indices.contains(i) else { return }
                        value = steps[i]      // 每动一格立即生效
                    }
                )
            )
            .frame(width: width, height: 20)

            Text(label(value))
                .font(.system(size: 12, design: .rounded)).bold()
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}

/// 带原生刻度的 NSSlider。刻度位置由 AppKit 按档位数计算，与滑块轨道天然对齐。
private struct TickedSlider: NSViewRepresentable {
    let count: Int
    @Binding var index: Int

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider(value: Double(index), minValue: 0, maxValue: Double(max(count - 1, 1)),
                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        s.numberOfTickMarks = count
        s.tickMarkPosition = .below
        s.allowsTickMarkValuesOnly = true      // 只能停在档位上，不会落在两档之间
        s.isContinuous = true                   // 拖动过程中就生效，松手才保存太迟钝
        s.controlSize = .small
        return s
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.index = $index
        nsView.maxValue = Double(max(count - 1, 1))
        nsView.numberOfTickMarks = count
        if Int(nsView.doubleValue.rounded()) != index {
            nsView.doubleValue = Double(index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(index: $index) }

    final class Coordinator: NSObject {
        var index: Binding<Int>
        init(index: Binding<Int>) { self.index = index }

        @objc func changed(_ sender: NSSlider) {
            let i = Int(sender.doubleValue.rounded())
            if index.wrappedValue != i { index.wrappedValue = i }
        }
    }
}

enum SizeSteps {
    /// 存储上限档位。0 = 不限制，放在最后一档。
    static let storageMB: [Int] = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 0]

    static func storageLabel(_ mb: Int) -> String {
        switch mb {
        case 0: return "不限制"
        case ..<1024: return "\(mb) MB"
        default:
            let g = Double(mb) / 1024
            return g == g.rounded() ? "\(Int(g)) GB" : String(format: "%.1f GB", g)
        }
    }

    static let itemCounts: [Int] = [100, 500, 1000, 5000, 10000, 50000, 100000, 0]

    static func countLabel(_ n: Int) -> String {
        switch n {
        case 0: return "不限制"
        case ..<1000: return "\(n) 条"
        default: return "\(n / 1000)k 条"
        }
    }

    static let itemSizeMB: [Int] = [1, 5, 10, 20, 50, 100, 200, 500]

    static func itemSizeLabel(_ mb: Int) -> String { "\(mb) MB" }
}
