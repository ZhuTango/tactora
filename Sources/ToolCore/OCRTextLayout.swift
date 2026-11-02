import Foundation
import CoreGraphics

enum OCRLineBreakMode: String, CaseIterable {
    case smart, original, singleLine

    static func saved(in defaults: UserDefaults) -> Self {
        if let raw = defaults.string(forKey: "ocrLineBreakMode"), let mode = Self(rawValue: raw) { return mode }
        // Preserve an explicitly configured legacy preference; new users get smart layout.
        if let old = defaults.object(forKey: "ocrKeepLineBreaks") as? Bool { return old ? .original : .singleLine }
        return .smart
    }
}

struct OCRTextLine {
    let text: String
    /// Image pixel coordinates, origin at bottom-left (same scale on both axes).
    let bounds: CGRect
}

enum OCRTextLayout {
    static func assemble(_ observations: [OCRTextLine], mode: OCRLineBreakMode) -> String {
        let lines = observations.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = lines.first else { return "" }
        if mode == .original { return lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        if mode == .singleLine {
            return lines.flatMap { $0.text.components(separatedBy: .newlines) }.reduce("") { result, line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return result + joiner(result, text) + text
            }
        }
        let rightEdge = lines.map { $0.bounds.maxX }.max() ?? 1
        var result = first.text
        for index in 1..<lines.count {
            let previous = lines[index - 1], current = lines[index]
            let h = max(previous.bounds.height, current.bounds.height, 0.001)
            let gap = previous.bounds.minY - current.bounds.maxY
            let text = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Large gaps denote paragraph spacing. Overlapping rows/columns stay separate.
            let paragraph = gap > h * 0.85
            let separate = paragraph || gap < -h * 0.35
                || abs(previous.bounds.minX - current.bounds.minX) > h * 1.4
                || abs(previous.bounds.height - current.bounds.height) > h * 0.3
                || rightEdge - previous.bounds.maxX > h * 2.5
                || isStructured(text) || isStructured(next)
                || text.last.map { "。！？.!?:：；;".contains($0) } == true
            result += separate ? (paragraph ? "\n\n" : "\n") : joiner(text, next)
            result += current.text
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStructured(_ text: String) -> Bool {
        if text.contains("\t") || text.contains("  ") { return true }
        let pattern = #"^(?:[-*•·●▪◦‣]\s*|\d+[.)、]\s*|[（(]?\d+[）)]\s*|[一二三四五六七八九十]+[、.)]|#{1,6}\s|```|(?:let|var|func|class|struct|enum|import|return|if|else|for|while|def|const|function|SELECT|FROM|WHERE)\b)|[{};]$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func joiner(_ left: String, _ right: String) -> String {
        guard let a = left.last, let b = right.first else { return "" }
        if a.isWhitespace || b.isWhitespace || "([{（【“‘".contains(a) || ",.;:!?，。；：！？、)]}）】”’".contains(b) { return "" }
        if isCJK(a) || isCJK(b) { return "" }
        return " "
    }
    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let n = scalar.value
            return (0x3400...0x9FFF).contains(n) || (0x20000...0x323AF).contains(n)
                || (0x3000...0x30FF).contains(n) || (0xAC00...0xD7AF).contains(n)
                || (0xFF00...0xFFEF).contains(n)
        }
    }
}
