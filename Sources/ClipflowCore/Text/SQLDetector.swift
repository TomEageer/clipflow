import Foundation

/// SQL 识别。
///
/// ⚠️ **这是结构合法性检查，不是语法校验。** 真正判断"这段 SQL 语法通过"需要一个
/// SQL parser（还得选方言），代价和收益完全不成比例。这里查三件事：
///
/// 1. **首关键字**必须是 SQL 动词（去掉前导注释后取第一个词）
/// 2. 该动词**必配的子句**要出现，且是独立的词
///    —— `SELECT` 要有 `FROM`、`UPDATE` 要有 `SET`、`INSERT` 要有 `INTO`…
/// 3. **括号与引号配平**（引号感知，`'it''s'` 这种转义算配平）
///
/// 三条都过才算。这足以把真 SQL 和「Update the docs」「select 一下这个方案」
/// 这类英文/中文句子分开 —— 光看首关键字的话它们全会被误判成 SQL。
public enum SQLDetector {

    /// 动词 → 必须同时出现的伴随关键字（任一即可）。
    /// 只列**必配**的：`SELECT 1` 合法但没有 FROM，所以 SELECT 那条另有兜底。
    private static let clauses: [String: [String]] = [
        "SELECT":   ["FROM"],
        "INSERT":   ["INTO"],
        "UPDATE":   ["SET"],
        "DELETE":   ["FROM"],
        "CREATE":   ["TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA", "TRIGGER",
                     "PROCEDURE", "FUNCTION", "SEQUENCE"],
        "ALTER":    ["TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA"],
        "DROP":     ["TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA", "TRIGGER",
                     "PROCEDURE", "FUNCTION", "SEQUENCE"],
        "TRUNCATE": ["TABLE"],
        "WITH":     ["SELECT"],
        "EXPLAIN":  ["SELECT", "INSERT", "UPDATE", "DELETE"],
        "MERGE":    ["INTO"],
        "REPLACE":  ["INTO"],
        "GRANT":    ["ON", "TO"],
        "REVOKE":   ["ON", "FROM"],
    ]

    public static func looksLikeSQL(_ text: String) -> Bool {
        let body = stripLeadingComments(text)
        guard body.count >= 10, body.count <= 2_000_000 else { return false }

        let upper = body.uppercased()
        guard let verb = firstWord(of: upper), let needed = clauses[verb] else { return false }

        // SELECT 1 / SELECT NOW() 这类没有 FROM 但确实是 SQL 的，单独放行
        if verb == "SELECT", !containsWord(upper, anyOf: needed) {
            guard containsWord(upper, anyOf: ["UNION", "WHERE"]) else { return false }
        } else if !containsWord(upper, anyOf: needed) {
            return false
        }

        return isBalanced(body)
    }

    // MARK: 细节

    /// 去掉前导的 `--` 行注释和 `/* */` 块注释 —— 从日志或工具里抠出来的 SQL 常带这些
    static func stripLeadingComments(_ text: String) -> String {
        var s = Substring(text)
        while true {
            s = s.drop { $0.isWhitespace }
            if s.hasPrefix("--") {
                s = s.drop { $0 != "\n" }
            } else if s.hasPrefix("/*") {
                guard let end = s.range(of: "*/") else { return "" }
                s = s[end.upperBound...]
            } else {
                return String(s)
            }
        }
    }

    static func firstWord(of s: String) -> String? {
        let w = s.drop { !$0.isLetter }.prefix { $0.isLetter }
        return w.isEmpty ? nil : String(w)
    }

    /// 必须整词匹配。不这么做的话 `FORMAT` 里含 `FROM`… 之类的会误命中。
    static func containsWord(_ haystack: String, anyOf words: [String]) -> Bool {
        let scalars = Array(haystack.unicodeScalars)
        func isWordChar(_ i: Int) -> Bool {
            guard i >= 0, i < scalars.count else { return false }
            let c = scalars[i]
            return CharacterSet.alphanumerics.contains(c) || c == "_"
        }
        for w in words {
            var search = haystack.startIndex..<haystack.endIndex
            while let r = haystack.range(of: w, range: search) {
                let start = haystack.distance(from: haystack.startIndex, to: r.lowerBound)
                let end = start + w.count
                if !isWordChar(start - 1), !isWordChar(end) { return true }
                guard r.upperBound < haystack.endIndex else { break }
                search = r.upperBound..<haystack.endIndex
            }
        }
        return false
    }

    /// 括号与引号配平。**必须引号感知** —— 字符串字面量里的括号不算数，
    /// `WHERE name = '张三)'` 不该因为那个右括号被判成不配平。
    static func isBalanced(_ s: String) -> Bool {
        var depth = 0
        var quote: Character?
        var it = s.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if let q = quote {
                if c == q {
                    // SQL 里连写两个引号是转义，仍在字符串内
                    if let n = it.next() {
                        if n == q { continue }
                        quote = nil
                        pending = n
                    } else {
                        quote = nil
                    }
                }
                continue
            }
            switch c {
            case "'", "\"", "`": quote = c
            case "(": depth += 1
            case ")": depth -= 1; if depth < 0 { return false }
            default: break
            }
        }
        return depth == 0 && quote == nil
    }
}
