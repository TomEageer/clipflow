import Foundation

/// 检索分词。中文按 bigram，拉丁按词（另拆 camelCase 子词）。
///
/// ## 为什么不能把拉丁文也按单字符切
///
/// 旧实现把每个非汉字**逐字符**入索引，靠短语查询做子串匹配。看着能用，实际是错的：
/// FTS5 的 unicode61 把标点当分隔符**丢掉，且不占位置**，于是短语可以跨词、跨标点乱拼。
///
/// 实测（用户报的）：搜 `test` 命中了
/// ``update `StaffInfo12` SET leaderStaffNo = '' …``
/// —— 因为 token 流是 `… a t e | S t a f f …`，反引号没了，
/// `update` 的尾巴接上 `Staff` 的头正好拼出 `t e s t`。
/// 文档一长，几乎什么都能"命中"，搜索结果就成了垃圾。
///
/// 现在拉丁按词入索引，词是原子的，跨不过去。子串能力靠两件事补回来：
/// - 查询端用**前缀匹配**（`user*` 命中 `userName`、`/Users/` 里的 `Users`）
/// - 入索引时额外拆 camelCase / 字母数字边界（`leaderStaffNo` 也能被 `staff` 搜到）
///
/// 顺带：token 数从"每字符一个"降到"每词一两个"，索引更小也更快。
public enum SearchTokenizer {

    /// 判定是否为需要 bigram 切分的表意文字（中日韩统一表意文字及扩展、假名）
    @inlinable
    public static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,      // 平假名 / 片假名
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 基本区
             0xF900...0xFAFF,      // CJK 兼容表意文字
             0x20000...0x2FA1F:    // CJK 扩展 B~F
            return true
        default:
            return false
        }
    }

    /// 文本里的一段连续同类字符。标点/空白只作分隔，不产生 run。
    enum Run: Equatable {
        case ideographs(String)
        case word(String)
    }

    /// 把文本切成「汉字段」和「字母数字段」，标点空白丢弃。
    static func runs(of text: String) -> [Run] {
        var out: [Run] = []
        var buf = ""
        var bufIsIdeograph = false

        func flush() {
            guard !buf.isEmpty else { return }
            out.append(bufIsIdeograph ? .ideographs(buf) : .word(buf))
            buf.removeAll(keepingCapacity: true)
        }

        for ch in text {
            let isIdeo = ch.unicodeScalars.count == 1 && isIdeograph(ch.unicodeScalars.first!)
            let isWord = ch.isLetter || ch.isNumber
            if isIdeo {
                if !bufIsIdeograph { flush(); bufIsIdeograph = true }
                buf.append(ch)
            } else if isWord {
                if bufIsIdeograph { flush(); bufIsIdeograph = false }
                buf.append(ch)
            } else {
                flush()
                bufIsIdeograph = false
            }
        }
        flush()
        return out
    }

    /// 把一个单词拆成子词：camelCase、字母↔数字边界。
    ///
    /// `leaderStaffNo` → `[leader, staff, no]`；`StaffInfo12` → `[staff, info, 12]`；
    /// `HTTPServer` → `[http, server]`（连续大写后面跟小写时，在最后一个大写前断开）。
    ///
    /// 单字符子词不要 —— `userA` 拆出个 `a` 只会让索引变大、让搜 `a` 命中一切。
    static func subwords(of word: String) -> [String] {
        let chars = Array(word)
        guard chars.count > 1 else { return [] }

        var parts: [String] = []
        var cur = String(chars[0])
        for i in 1..<chars.count {
            let prev = chars[i - 1], c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let boundary =
                (c.isUppercase && (prev.isLowercase || prev.isNumber))       // aB
                || (c.isUppercase && prev.isUppercase && (next?.isLowercase ?? false)) // HTTPServer
                || (c.isNumber != prev.isNumber)                             // a1 / 1a
            if boundary {
                parts.append(cur)
                cur = String(c)
            } else {
                cur.append(c)
            }
        }
        parts.append(cur)

        let lowered = word.lowercased()
        return parts.map { $0.lowercased() }.filter { $0.count > 1 && $0 != lowered }
    }

    /// 入索引用的词元流（以空格分隔，交给 FTS5 的 unicode61 再切一次）。
    ///
    /// - 连续汉字 → 相邻两字的 bigram（`订单支付` → `订单 单支 支付`）
    /// - 单个孤立汉字 → 原样
    /// - 字母数字段 → 整词 + camelCase/数字边界拆出的子词
    public static func tokenize(_ text: String) -> String {
        var out: [String] = []
        for run in runs(of: text) {
            switch run {
            case .ideographs(let s):
                let chars = Array(s)
                if chars.count == 1 {
                    out.append(String(chars[0]))
                } else {
                    for i in 0..<(chars.count - 1) {
                        out.append(String(chars[i]) + String(chars[i + 1]))
                    }
                }
            case .word(let w):
                out.append(w.lowercased())
                out.append(contentsOf: subwords(of: w))
            }
        }
        return out.joined(separator: " ")
    }

    /// 把用户输入的查询串转成 FTS5 MATCH 表达式。
    ///
    /// - 汉字段用**短语查询**（要求 bigram 连续），保证「订单支付」不会匹配到
    ///   只是分别含有「订单」和「支付」的无关条目。
    /// - 字母数字段用**前缀查询** `word*` —— 用户搜 `user` 要能找到 `userName`。
    /// - 各段之间是 AND。
    ///
    /// ⚠️ 单个汉字只能退化成前缀（`单*` 命中 `单支`，命不中 `订单` 里作第二字的那个）：
    /// 索引里存的是 bigram，没有单字词元。要根治得连 unigram 一起入索引，
    /// 索引会大一倍，暂不值得 —— 单字查询本来也筛不出什么。
    public static func matchExpression(for query: String) -> String? {
        var clauses: [String] = []
        for term in query.split(whereSeparator: { $0.isWhitespace }) {
            for run in runs(of: String(term)) {
                switch run {
                case .ideographs(let s):
                    let chars = Array(s)
                    if chars.count == 1 {
                        clauses.append(quoted(String(chars[0])) + "*")
                    } else {
                        let grams = (0..<(chars.count - 1)).map {
                            String(chars[$0]) + String(chars[$0 + 1])
                        }
                        clauses.append(quoted(grams.joined(separator: " ")))
                    }
                case .word(let w):
                    clauses.append(quoted(w.lowercased()) + "*")
                }
            }
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
    }

    /// FTS5 字符串字面量：双引号包裹，内部双引号翻倍。
    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
