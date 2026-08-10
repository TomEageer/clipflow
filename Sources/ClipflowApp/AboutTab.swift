import AppKit
import SwiftUI

/// 关于页：版本、作者、反馈、捐赠、许可证。
///
/// 放在设置窗口的一个标签页里，而不是单独的关于窗口 —— 少一个窗口，
/// 用户也不用记「关于」和「设置」是两个地方。
struct AboutTab: View {

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                Divider().padding(.horizontal, 40)

                linkSection(
                    title: "反馈与支持",
                    rows: [
                        (.init(icon: "ladybug", title: "报告问题 / 提功能建议",
                               detail: "GitHub Issues",
                               url: "https://github.com/TomEageer/clipflow/issues")),
                        (.init(icon: "envelope", title: "直接联系作者",
                               detail: "tomeageer@gmail.com",
                               url: "mailto:tomeageer@gmail.com")),
                        (.init(icon: "globe", title: "个人主页",
                               detail: "tomeageer.com",
                               url: "https://tomeageer.com")),
                    ])

                linkSection(
                    title: "赞赏支持",
                    rows: [
                        (.init(icon: "heart", title: "请作者喝杯咖啡",
                               detail: "支付宝 / 微信 / 加密货币",
                               url: "https://github.com/TomEageer/clipflow/blob/main/DONATE.md")),
                    ],
                    footnote: "Clipflow 免费开源，没有广告、没有埋点、没有付费版。所有功能永久免费，赞赏完全自愿。")

                linkSection(
                    title: "开源",
                    rows: [
                        (.init(icon: "chevron.left.forwardslash.chevron.right", title: "源码",
                               detail: "github.com/TomEageer/clipflow",
                               url: "https://github.com/TomEageer/clipflow")),
                        (.init(icon: "doc.text", title: "许可证",
                               detail: "MIT",
                               url: "https://github.com/TomEageer/clipflow/blob/main/LICENSE")),
                    ])

                privacyNote

                Spacer(minLength: 10)
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable().frame(width: 84, height: 84)
            }
            Text("Clipflow").font(.system(size: 22, weight: .semibold))
            Text("macOS 剪贴板管理器")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("版本 \(version)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var privacyNote: some View {
        VStack(spacing: 5) {
            Label("所有数据只存在你的 Mac 上", systemImage: "lock.shield")
                .font(.system(size: 11, weight: .medium))
            Text("不联网、不上传、不埋点。密码管理器复制的内容不会被记录，"
                 + "识别为 token / 密钥的内容不进搜索索引。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(.top, 4)
    }

    // MARK: 小件

    private struct Row {
        let icon: String, title: String, detail: String, url: String
    }

    @ViewBuilder
    private func linkSection(title: String, rows: [Row], footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, r in
                    if idx > 0 { Divider().padding(.leading, 34) }
                    LinkRow(row: r)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))

            if let footnote {
                Text(footnote)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: 420)
    }

    private struct LinkRow: View {
        let row: Row
        @State private var hovering = false

        var body: some View {
            Button {
                if let u = URL(string: row.url) { NSWorkspace.shared.open(u) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: row.icon)
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(row.title).font(.system(size: 12))
                    Spacer()
                    Text(row.detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(hovering ? Color.primary.opacity(0.05) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}
