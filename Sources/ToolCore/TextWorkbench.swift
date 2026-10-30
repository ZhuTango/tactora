import Foundation

enum TextToolMode: Int, CaseIterable { case automatic, json, timestamp, compare, basic }
enum JSONTextOperation: Int, CaseIterable { case format, compact, escape, unescape }
enum TimestampUnit: Int, CaseIterable { case automatic, seconds, milliseconds }

enum TextWorkbenchError: LocalizedError {
    case invalidJSON(String), invalidTimestamp, stringRequired, diffTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): return "JSON 格式错误 / Invalid JSON: " + detail
        case .invalidTimestamp: return "请输入有效时间戳（自动识别 10 位秒或 13 位毫秒） / Enter a valid timestamp."
        case .stringRequired: return "请输入带双引号的 JSON 字符串 / Expected a quoted JSON string."
        case .diffTooLarge: return "对比最多支持每份 2,000 行、128 KB / Compare up to 2,000 lines and 128 KB per input."
        }
    }
}

enum TextWorkbench {
    static func detect(_ source: String) -> TextToolMode {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") || text.unicodeScalars.first?.value == 34 { return .json }
        let digits = text.hasPrefix("-") ? String(text.dropFirst()) : text
        if [10, 13].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return .timestamp }
        return .basic
    }
    static func json(_ source: String, operation: JSONTextOperation) throws -> String {
        guard source.utf8.count <= TextProcessor.maximumBytes else { throw TextProcessingError.tooLarge }
        if operation == .escape {
            let data = try JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let tokens = try validatedTokens(source)
        if operation == .unescape {
            guard tokens.count == 1, tokens[0].text.unicodeScalars.first?.value == 34,
                  let text = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed]) as? String else { throw TextWorkbenchError.stringRequired }
            return text
        }
        if operation == .compact { return tokens.map(\.text).joined() }
        var result = "", depth = 0, outputBytes = 0
        func append(_ text: String) throws {
            outputBytes += text.utf8.count
            guard outputBytes <= 4 * TextProcessor.maximumBytes else { throw TextProcessingError.tooLarge }
            result += text
        }
        func newline() throws { try append("\n" + String(repeating: "  ", count: depth)) }
        for (index, token) in tokens.enumerated() {
            let value = token.text
            switch value {
            case "{", "[":
                try append(value); depth += 1
                if index + 1 < tokens.count, !["}", "]"].contains(tokens[index + 1].text) { try newline() }
            case "}", "]":
                depth -= 1
                if index > 0, !["{", "["].contains(tokens[index - 1].text) { try newline() }
                try append(value)
            case ",": try append(","); try newline()
            case ":": try append(": ")
            default: try append(value)
            }
        }
        return result
    }
    private struct Token { let text: String; let line: Int; let column: Int }
    /// Validate strict JSON while preserving numbers, escapes, key order and duplicate keys verbatim.
    private static func validatedTokens(_ source: String) throws -> [Token] {
        let chars = source.unicodeScalars.map(String.init)
        var tokens = [Token](), i = 0, line = 1, column = 1
        func advance() { if chars[i] == "\n" || chars[i] == "\r\n" { line += 1; column = 1 } else { column += 1 }; i += 1 }
        func fail(_ reason: String, at token: Token? = nil) -> TextWorkbenchError {
            .invalidJSON("line \(token?.line ?? line), column \(token?.column ?? column): " + reason)
        }
        while i < chars.count {
            if [" ", "\t", "\r", "\n", "\r\n"].contains(chars[i]) { advance(); continue }
            let start = i, startLine = line, startColumn = column
            if "{}[]:,".contains(chars[i]) { advance() }
            else if chars[i] == "\"" {
                advance()
                var closed = false
                while i < chars.count {
                    if chars[i] == "\\" { advance(); if i < chars.count { advance() } }
                    else if chars[i] == "\"" { advance(); closed = true; break }
                    else { advance() }
                }
                guard closed else { throw fail("Unterminated string") }
            } else {
                while i < chars.count, !"{}[]:,".contains(chars[i]), ![" ", "\t", "\r", "\n", "\r\n"].contains(chars[i]) { advance() }
            }
            tokens.append(Token(text: chars[start..<i].joined(), line: startLine, column: startColumn))
        }
        var cursor = 0
        let number = try NSRegularExpression(pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)
        func consume(_ expected: String) throws {
            guard cursor < tokens.count, tokens[cursor].text == expected else { throw fail("Expected " + expected, at: cursor < tokens.count ? tokens[cursor] : nil) }
            cursor += 1
        }
        func string() throws {
            guard cursor < tokens.count else { throw fail("Expected string") }
            let token = tokens[cursor]
            guard token.text.unicodeScalars.first?.value == 34,
                  (try? JSONSerialization.jsonObject(with: Data(token.text.utf8), options: [.fragmentsAllowed])) is String else { throw fail("Invalid string", at: token) }
            cursor += 1
        }
        func value(_ depth: Int) throws {
            guard depth <= 128 else { throw fail("Nesting exceeds 128 levels") }
            guard cursor < tokens.count else { throw fail("Expected value") }
            let token = tokens[cursor]
            switch token.text {
            case "{":
                cursor += 1
                if cursor < tokens.count, tokens[cursor].text == "}" { cursor += 1; return }
                while true {
                    try string(); try consume(":"); try value(depth + 1)
                    if cursor < tokens.count, tokens[cursor].text == "," { cursor += 1; continue }
                    try consume("}"); return
                }
            case "[":
                cursor += 1
                if cursor < tokens.count, tokens[cursor].text == "]" { cursor += 1; return }
                while true {
                    try value(depth + 1)
                    if cursor < tokens.count, tokens[cursor].text == "," { cursor += 1; continue }
                    try consume("]"); return
                }
            case "true", "false", "null": cursor += 1
            default:
                if token.text.unicodeScalars.first?.value == 34 { try string(); return }
                let range = NSRange(location: 0, length: (token.text as NSString).length)
                guard number.firstMatch(in: token.text, range: range)?.range == range else { throw fail("Invalid value", at: token) }
                cursor += 1
            }
        }
        try value(0)
        guard cursor == tokens.count else { throw fail("Unexpected trailing content", at: tokens[cursor]) }
        return tokens
    }
    static func timestamp(_ source: String, unit: TimestampUnit, timeZone: TimeZone = .current) throws -> String {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let number = Double(text), number.isFinite else { throw TextWorkbenchError.invalidTimestamp }
        let effective: TimestampUnit
        if unit == .automatic {
            let digits = text.hasPrefix("-") ? String(text.dropFirst()) : text
            guard [10, 13].contains(digits.count), !digits.contains(".") else { throw TextWorkbenchError.invalidTimestamp }
            effective = digits.count == 13 ? .milliseconds : .seconds
        } else { effective = unit }
        let seconds = effective == .milliseconds ? number / 1000 : number
        guard (-62_135_596_800...253_402_300_799).contains(seconds) else { throw TextWorkbenchError.invalidTimestamp }
        let date = Date(timeIntervalSince1970: seconds)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        format.timeZone = timeZone
        let local = format.string(from: date)
        format.timeZone = TimeZone(secondsFromGMT: 0)
        return "Local [\(timeZone.identifier)]\n\(local)\n\nUTC\n\(format.string(from: date))\n\nUnix seconds\n\(seconds)\n\nUnix milliseconds\n\(seconds * 1000)"
    }
    static func diff(_ original: String, _ revised: String) throws -> String {
        guard original.utf8.count <= 131_072, revised.utf8.count <= 131_072 else { throw TextWorkbenchError.diffTooLarge }
        func lines(_ text: String) -> [String] {
            if text.isEmpty { return [] }
            return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        }
        let a = lines(original), b = lines(revised)
        guard a.count <= 2000, b.count <= 2000 else { throw TextWorkbenchError.diffTooLarge }
        let changes = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0, output = [String]()
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { output.append("- " + a[i]); i += 1 }
            else if j < b.count, inserted.contains(j) { output.append("+ " + b[j]); j += 1 }
            else if i < a.count, j < b.count { output.append("  " + a[i]); i += 1; j += 1 }
            else { break }
        }
        return output.joined(separator: "\n")
    }
}
