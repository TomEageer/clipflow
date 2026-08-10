import SwiftUI

/// 分档滑块。
///
/// 用它替代数字输入框：`TextField` 要按回车或失焦才提交，用户拖完数字看着变了、
/// 其实没保存 —— 「设置不了存储上限」就是这么来的。滑块每动一格立即写入。
struct SteppedSlider<T: Equatable & Comparable & BinaryInteger>: View {

    let steps: [T]
    let label: (T) -> String
    @Binding var value: T

    /// 当前值不在档位里时（比如老版本用输入框设过 700MB），落到**最接近**的一档。
    /// 直接 `firstIndex ?? 0` 会静默显示成最小档，用户没动过却看到值变了。
    private var nearestIndex: Int {
        if let exact = steps.firstIndex(of: value) { return exact }
        // 0 语义是"不限制"，不参与距离比较
        let candidates = steps.enumerated().filter { $0.element != 0 }
        guard let best = candidates.min(by: {
            abs(Int($0.element) - Int(value)) < abs(Int($1.element) - Int(value))
        }) else { return 0 }
        return best.offset
    }

    private var index: Binding<Double> {
        Binding(
            get: { Double(nearestIndex) },
            set: { newValue in
                let i = Int(newValue.rounded())
                guard steps.indices.contains(i) else { return }
                value = steps[i]     // 每动一格立即生效
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Slider(value: index, in: 0...Double(max(steps.count - 1, 1)),
                       step: 1)
                Text(label(value))
                    .font(.system(size: 12, design: .rounded)).bold()
                    .frame(width: 74, alignment: .trailing)
                    .monospacedDigit()
            }
            // 刻度：首、中、尾，够定位又不挤
            HStack {
                Text(label(steps.first ?? value))
                Spacer()
                if steps.count > 2 { Text(label(steps[steps.count / 2])); Spacer() }
                Text(label(steps.last ?? value))
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
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

    /// 条目数上限。0 = 不限制。
    static let itemCounts: [Int] = [100, 500, 1000, 5000, 10000, 50000, 100000, 0]

    static func countLabel(_ n: Int) -> String {
        switch n {
        case 0: return "不限制"
        case ..<1000: return "\(n) 条"
        default: return "\(n / 1000)k 条"
        }
    }

    /// 单条大小上限
    static let itemSizeMB: [Int] = [1, 5, 10, 20, 50, 100, 200, 500]

    static func itemSizeLabel(_ mb: Int) -> String { "\(mb) MB" }
}
