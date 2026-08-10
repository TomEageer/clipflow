import AppKit
import Foundation

/// 检查更新。
///
/// 不引入 Sparkle —— 只需要"有没有新版本"这一件事，一个 GitHub API 请求就够，
/// 加一整个更新框架不值得，而且 Sparkle 会带来自动下载与自签名密钥的复杂度。
///
/// **这是本应用唯一的网络请求**，且只在用户点击或显式勾选自动检查时发生。
/// 不发送任何设备信息、不带标识符、不统计。
enum Updater {

    static let repo = "TomEageer/clipflow"
    static var releasePageURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    struct Result: Sendable {
        var latest: String
        var current: String
        var hasUpdate: Bool
        var notes: String
    }

    enum Failure: Error, LocalizedError {
        case network(String)
        case parse

        var errorDescription: String? {
            switch self {
            case .network(let m): return "无法连接 GitHub：\(m)"
            case .parse: return "无法解析版本信息"
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func check() async throws -> Result {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 不带任何可识别身份的信息
        req.setValue("Clipflow", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw Failure.parse
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (obj["body"] as? String) ?? ""
        return Result(latest: latest, current: currentVersion,
                      hasUpdate: isNewer(latest, than: currentVersion), notes: notes)
    }

    /// 语义化版本比较。逐段比数字，段数不同时短的补 0。
    /// 不用字符串比较 —— "0.10.0" < "0.9.0" 会判错。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func openReleasePage() {
        NSWorkspace.shared.open(releasePageURL)
    }

    static func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/blob/main/DONATE.md")!)
    }
}

/// 更新检查的界面状态
struct UpdateState: Sendable {
    var isChecking = false
    var hasUpdate = false
    var latest: String?
    var message: String = "尚未检查"

    static func checking() -> UpdateState {
        UpdateState(isChecking: true, message: "检查中…")
    }

    static func upToDate(_ v: String) -> UpdateState {
        UpdateState(message: "已是最新（\(v)）")
    }

    static func available(_ v: String) -> UpdateState {
        UpdateState(hasUpdate: true, latest: v, message: "有新版本 \(v)")
    }

    static func failed(_ e: Error) -> UpdateState {
        UpdateState(message: (e as? LocalizedError)?.errorDescription ?? "检查失败")
    }
}
