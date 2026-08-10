import Foundation

/// 中文 bigram 分词。
///
/// 为什么需要：FTS5 自带的 unicode61 tokenizer 把连续汉字当成**一个**词元，
/// 搜「订单」匹配不到「订单支付回调」。所以在应用层把汉字切成 2-gram 再入索引。
///
/// 为什么是 bigram 而不是真分词：零依赖、无词典、无歧义切分问题；
/// 配合 FTS5 `detail=full` 的**短语查询**（要求 bigram 连续出现）可保证精度。
/// 实测：`detail=column` / `detail=none` 不支持短语查询，中文检索会退化成 AND 匹配。
///
/// 注：spellfix1 那类拼写容错对中文基本无效（按编辑距离纠拉丁词），不是替代品。
public enum BigramTokenizer {

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

    /// 把文本转成用于写入 FTS 索引的词元流。
    ///
    /// - 连续汉字 → 相邻两字组成的 bigram（"订单支付" → "订单 单支 支付"）
    /// - 单个孤立汉字 → 原样保留
    /// - 非汉字 → 原样保留（交给 unicode61 继续切）
    public static func tokenize(_ text: String) -> String {
        var out: [String] = []
        out.reserveCapacity(text.count)
        var buf: [Character] = []

        func flushIdeographs() {
            if buf.count == 1 {
                out.append(String(buf[0]))
            } else if buf.count > 1 {
                for i in 0..<(buf.count - 1) {
                    out.append(String(buf[i]) + String(buf[i + 1]))
                }
            }
            buf.removeAll(keepingCapacity: true)
        }

        for ch in text {
            if let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, isIdeograph(s) {
                buf.append(ch)
            } else {
                flushIdeographs()
                out.append(String(ch))
            }
        }
        flushIdeographs()
        return out.joined(separator: " ")
    }

    /// 把用户输入的查询串转成 FTS5 MATCH 表达式。
    ///
    /// 汉字段落用**短语查询**（要求 bigram 连续），保证「订单支付」不会匹配到
    /// 只是分别含有「订单」和「支付」的无关条目。
    public static func matchExpression(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 按空白拆成若干查询词，词之间是 AND
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var clauses: [String] = []

        for term in terms {
            let toks = tokenize(term).split(separator: " ").map(String.init)
            guard !toks.isEmpty else { continue }
            // 每个词内部用短语（引号包裹整串，FTS5 视为 phrase）
            let escaped = toks.map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            clauses.append("\"" + escaped.joined(separator: " ") + "\"")
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }
}
