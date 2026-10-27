import Foundation

// Offsets are UTF-16 ranges in the original preview, including emoji and composed characters.
enum ClipboardSearchHighlight {
    static func ranges(in text: String, query: String) -> [NSRange] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let original = text as NSString
        var matches: [NSRange] = []
        func occurrences(_ needle: String, in value: NSString) -> [NSRange] {
            var found: [NSRange] = []
            var start = 0
            while start < value.length {
                let range = value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    range: NSRange(location: start, length: value.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append(range); start = NSMaxRange(range)
            }
            return found
        }
        let needsPinyin = tokens.contains { token in
            token.rangeOfCharacter(from: .letters) != nil && occurrences(token, in: original).isEmpty
        }
        var full = "", initials = ""
        var fullMap: [NSRange] = [], initialMap: [NSRange] = []
        var offset = 0
        for character in (needsPinyin ? text : "") {
            let piece = String(character)
            let range = NSRange(location: offset, length: piece.utf16.count)
            offset += range.length
            let chinese = piece.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
            let latin = (chinese ? (piece.applyingTransform(.mandarinToLatin, reverse: false) ?? piece) : piece)
                .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let letters = latin.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            full += letters
            fullMap.append(contentsOf: Array(repeating: range, count: letters.utf16.count))
            if let first = letters.first {
                initials.append(first); initialMap.append(range)
            }
        }
        for token in tokens {
            let direct = occurrences(token, in: original)
            if !direct.isEmpty { matches += direct; continue }
            let folded = token.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard folded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            for (value, map) in [(full, fullMap), (initials, initialMap)] {
                for range in occurrences(folded, in: value as NSString) where NSMaxRange(range) <= map.count {
                    let first = map[range.location], last = map[NSMaxRange(range) - 1]
                    matches.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                }
            }
        }
        var merged: [NSRange] = []
        for range in matches.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }
}
