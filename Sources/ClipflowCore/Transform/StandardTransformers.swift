import Foundation

// MARK: - 文本

public struct PlainTextTransformer: Transformer {
    public let id = "text.plain"
    public let title = "转为纯文本"
    public let group = TransformGroup.text
    public let developerOnly = false
    public init() {}
    public func canApply(to text: String) -> Bool { !text.isEmpty }
    public func apply(to text: String) throws -> String { text }
}

public struct TrimBlankLinesTransformer: Transformer {
    public let id = "text.trim-blank"
    public let title = "去掉多余空行"
    public let group = TransformGroup.text
    public let developerOnly = false
    public init() {}
    /// 只在真有连续空行时才提供 —— 点了没变化的动作最恼人
    public func canApply(to text: String) -> Bool { text.contains("\n\n\n") }
    public func apply(to text: String) throws -> String {
        var s = text
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct UppercaseTransformer: Transformer {
    public let id = "text.upper"
    public let title = "转大写"
    public let group = TransformGroup.text
    public let developerOnly = false
    public init() {}
    public func canApply(to text: String) -> Bool { text != text.uppercased() }
    public func apply(to text: String) throws -> String { text.uppercased() }
}

public struct LowercaseTransformer: Transformer {
    public let id = "text.lower"
    public let title = "转小写"
    public let group = TransformGroup.text
    public let developerOnly = false
    public init() {}
    public func canApply(to text: String) -> Bool { text != text.lowercased() }
    public func apply(to text: String) throws -> String { text.lowercased() }
}

// MARK: - JSON

public struct JSONPrettyTransformer: Transformer {
    public let id = "json.pretty"
    public let title = "JSON 格式化"
    public let group = TransformGroup.json
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool { JSONDetector.looksLikeJSON(text) }
    public func apply(to text: String) throws -> String {
        guard let s = JSONDetector.pretty(text) else { throw TransformError.notApplicable("不是合法 JSON") }
        return s
    }
}

public struct JSONMinifyTransformer: Transformer {
    public let id = "json.minify"
    public let title = "JSON 压缩"
    public let group = TransformGroup.json
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool { JSONDetector.looksLikeJSON(text) }
    public func apply(to text: String) throws -> String {
        guard let s = JSONDetector.minify(text) else { throw TransformError.notApplicable("不是合法 JSON") }
        return s
    }
}

/// 把一段 JSON 变成可嵌进字符串字面量的形式（转义引号与换行）
public struct JSONEscapeTransformer: Transformer {
    public let id = "json.escape"
    public let title = "JSON 转义"
    public let group = TransformGroup.json
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool {
        !text.isEmpty && (text.contains("\"") || text.contains("\n") || text.contains("\\"))
    }
    public func apply(to text: String) throws -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\", with: "\\\\")
        s = s.replacingOccurrences(of: "\"", with: "\\\"")
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        s = s.replacingOccurrences(of: "\r", with: "\\r")
        s = s.replacingOccurrences(of: "\t", with: "\\t")
        return s
    }
}

/// 反向：把日志里抠出来的转义 JSON 还原成可读的
public struct JSONUnescapeTransformer: Transformer {
    public let id = "json.unescape"
    public let title = "JSON 反转义"
    public let group = TransformGroup.json
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool {
        text.contains("\\\"") || text.contains("\\n") || text.contains("\\\\")
    }
    public func apply(to text: String) throws -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\r", with: "\r")
        s = s.replacingOccurrences(of: "\\t", with: "\t")
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
        s = s.replacingOccurrences(of: "\\\\", with: "\\")
        return s
    }
}

// MARK: - 编码

public struct URLEncodeTransformer: Transformer {
    public let id = "url.encode"
    public let title = "URL 编码"
    public let group = TransformGroup.encoding
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool { !text.isEmpty && text.count < 100_000 }
    public func apply(to text: String) throws -> String {
        // 用 urlQueryAllowed 再减去 & = ? + —— 这几个在 query 里有语法含义，
        // 用户要编码一段值时正是希望它们被转义
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let s = text.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw TransformError.notApplicable("无法编码")
        }
        return s
    }
}

public struct URLDecodeTransformer: Transformer {
    public let id = "url.decode"
    public let title = "URL 解码"
    public let group = TransformGroup.encoding
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool { text.contains("%") }
    public func apply(to text: String) throws -> String {
        guard let s = text.removingPercentEncoding else {
            throw TransformError.notApplicable("不是合法的 URL 编码")
        }
        return s
    }
}

public struct Base64EncodeTransformer: Transformer {
    public let id = "base64.encode"
    public let title = "Base64 编码"
    public let group = TransformGroup.encoding
    public let developerOnly = true
    public init() {}
    public func canApply(to text: String) -> Bool { !text.isEmpty && text.count < 1_000_000 }
    public func apply(to text: String) throws -> String {
        Data(text.utf8).base64EncodedString()
    }
}

public struct Base64DecodeTransformer: Transformer {
    public let id = "base64.decode"
    public let title = "Base64 解码"
    public let group = TransformGroup.encoding
    public let developerOnly = true
    public init() {}

    /// 只在"看着像 base64"时提供：长度是 4 的倍数、字符集吻合、且能解成合法 UTF-8。
    /// 不做这层判断的话，任何一段英文都会显示"可 Base64 解码"，然后解出乱码。
    public func canApply(to text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8, t.count % 4 == 0 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let d = Data(base64Encoded: t), let s = String(data: d, encoding: .utf8) else { return false }
        return !s.isEmpty
    }

    public func apply(to text: String) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Data(base64Encoded: t), let s = String(data: d, encoding: .utf8) else {
            throw TransformError.notApplicable("不是合法的 Base64 文本")
        }
        return s
    }
}
