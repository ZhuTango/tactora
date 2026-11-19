import Foundation

/// Maps normalized text and pinyin back to original UTF-16 ranges for AppKit.
/// Constructed once per action, not while rendering each keystroke.
struct QuickActionHighlightIndex {
    private var plain = ""
    private(set) var latin = "", initials = ""
    private var plainMap: [NSRange] = [], latinMap: [NSRange] = [], initialMap: [NSRange] = []
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    init(_ title: String) {
        var offset = 0
        var previousASCIIWord = false
        for character in title {
            let text = String(character)
            let range = NSRange(location: offset, length: text.utf16.count)
            offset += range.length
            let normalized = Self.fold(text)
            plain += normalized
            plainMap += Array(repeating: range, count: normalized.utf16.count)
            let syllable = Self.fold(text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
                .filter { $0.isLetter || $0.isNumber }
            latin += syllable
            latinMap += Array(repeating: range, count: syllable.utf16.count)
            let asciiWord = text.unicodeScalars.allSatisfy { $0.isASCII } && !syllable.isEmpty
            if let first = syllable.first, !asciiWord || !previousASCIIWord {
                let value = String(first)
                initials += value
                initialMap += Array(repeating: range, count: value.utf16.count)
            }
            previousASCIIWord = asciiWord
        }
    }
    func ranges(_ query: String) -> [NSRange] {
        var hits = Set<Int>()
        var originals: [Int: NSRange] = [:]
        for token in Self.fold(query).split(whereSeparator: { $0.isWhitespace }) {
            for (text, map) in [(plain, plainMap), (latin, latinMap), (initials, initialMap)] {
                let source = text as NSString
                var cursor = 0
                var found = false
                while cursor < source.length {
                    let match = source.range(of: String(token), options: [], range: NSRange(location: cursor, length: source.length - cursor))
                    guard match.location != NSNotFound else { break }
                    found = true
                    for index in match.location..<NSMaxRange(match) {
                        let original = map[index]
                        hits.insert(original.location); originals[original.location] = original
                    }
                    cursor = NSMaxRange(match)
                }
                if found { break }
            }
        }
        return hits.sorted().compactMap { originals[$0] }
    }
}
