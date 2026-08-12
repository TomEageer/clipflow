import Foundation

/// Shell 命令识别（curl / git / docker / npm …）。
///
/// 和 `SQLDetector` 一样是**结构判断，不是语法校验** —— 真解析 shell 语法要处理
/// 引号、展开、管道、子 shell、here-doc，代价和收益不成比例。这里查：
///
/// 1. 第一行（剥掉前导 `$ `、`#!/...` 之后）的**首词是已知命令**，或整段带 shebang
/// 2. 首词后面**跟着参数或子命令** —— 光一个 `git` 不算，`git status` 才算
/// 3. 引号配平（多行命令用 `\` 续行时尤其容易被截断，配不平说明抠残了）
///
/// 第 2 条是防误判的关键：`docker`、`open`、`say`、`find` 这些词在中英文句子里
/// 出现得太频繁，只看首词的话「find 一下这个文件」会被判成 shell。
public enum ShellDetector {

    /// 高置信度：这些词开头基本不可能是自然语言
    private static let strongCommands: Set<String> = [
        "curl", "wget", "ssh", "scp", "rsync", "git", "docker", "kubectl", "helm",
        "npm", "npx", "yarn", "pnpm", "pip", "pip3", "brew", "apt", "apt-get", "yum",
        "systemctl", "journalctl", "launchctl", "codesign", "xcrun", "swift",
        "gradle", "mvn", "java", "node", "deno", "cargo", "go", "make", "cmake",
        "psql", "mysql", "redis-cli", "sqlite3", "mongosh",
        "tar", "unzip", "chmod", "chown", "ln", "df", "du", "ps", "kill", "pkill",
        "lsof", "netstat", "dig", "nslookup", "ifconfig", "traceroute",
        "sudo", "defaults", "osascript", "pbcopy", "pbpaste", "screencapture",
    ]

    /// 常见但也常出现在自然语言里：要求**更强的证据**（带 `-` 开头的选项或路径）
    private static let weakCommands: Set<String> = [
        "cd", "ls", "cat", "cp", "mv", "rm", "mkdir", "touch", "echo", "grep",
        "sed", "awk", "find", "open", "which", "man", "top", "head", "tail",
        "sort", "uniq", "wc", "diff", "export", "source", "python", "python3",
    ]

    public static func looksLikeShell(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 4, body.count <= 200_000 else { return false }

        // shebang 直接算
        if body.hasPrefix("#!") { return true }

        var line = firstMeaningfulLine(body)
        // 从终端/文档里拷出来常带提示符
        for prefix in ["$ ", "% ", "> ", "❯ ", "➜ "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        // `sudo xxx` 看后面那个才有意义
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "sudo", words.count > 1 { words.removeFirst() }
        guard let cmd = words.first, words.count >= 2 else { return false }

        let rest = words.dropFirst()
        if strongCommands.contains(cmd) {
            return isQuoteBalanced(body)
        }
        if weakCommands.contains(cmd) {
            // 必须看见选项或路径，否则「find 一下这个文件」会被误判
            let hasEvidence = rest.contains { $0.hasPrefix("-") || $0.contains("/") || $0.contains("*") }
            return hasEvidence && isQuoteBalanced(body)
        }
        return false
    }

    /// 是不是一条 curl 命令。UI 上想单独标 curl 时用。
    public static func looksLikeCurl(_ text: String) -> Bool {
        guard looksLikeShell(text) else { return false }
        var line = firstMeaningfulLine(text.trimmingCharacters(in: .whitespacesAndNewlines))
        for prefix in ["$ ", "% ", "> ", "❯ ", "➜ "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "sudo", words.count > 1 { words.removeFirst() }
        return words.first == "curl"
    }

    // MARK: 细节

    /// 跳过空行和纯注释行 —— 从文档里拷的命令常常前面带一行 `# 说明`
    static func firstMeaningfulLine(_ s: String) -> String {
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return line
        }
        return ""
    }

    /// 单双引号各自配平。多行命令用 `\` 续行时最容易被截断，配不平说明抠残了。
    static func isQuoteBalanced(_ s: String) -> Bool {
        var single = 0, double = 0
        var escaped = false
        for c in s {
            if escaped { escaped = false; continue }
            switch c {
            case "\\": escaped = true
            case "'" where double % 2 == 0: single += 1
            case "\"" where single % 2 == 0: double += 1
            default: break
            }
        }
        return single % 2 == 0 && double % 2 == 0
    }
}
