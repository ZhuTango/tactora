import Foundation

struct QuickAction {
    enum Destination {
        case command(String)
        case application(String)
        case text(String)
        case awake(Int)
    }
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let destination: Destination
    private let index: AppSearchIndex
    private let titleIndex: QuickActionHighlightIndex

    init(id: String, title: String, detail: String = "", keywords: String = "", symbol: String = "command", destination: Destination) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.destination = destination
        index = AppSearchIndex(source: title + " " + keywords)
        titleIndex = QuickActionHighlightIndex(title)
    }

    func highlightRanges(_ query: String) -> [NSRange] { titleIndex.ranges(query) }

    func matchRank(_ query: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return 3 }
        let title = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        if title == folded { return 0 }
        if title.hasPrefix(folded) { return 1 }
        return index.matches(query) ? 2 : nil
    }
}

final class QuickActionHistory {
    private let defaults: UserDefaults
    private(set) var favorites: Set<String>
    private(set) var recent: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Set((defaults.stringArray(forKey: "quickActions.favorites") ?? []).prefix(100))
        var seen = Set<String>()
        recent = (defaults.stringArray(forKey: "quickActions.recent") ?? []).filter { seen.insert($0).inserted }.prefix(30).map { $0 }
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) }
        else if favorites.count < 100 { favorites.insert(id) }
        defaults.set(favorites.sorted(), forKey: "quickActions.favorites")
    }
    func record(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(30))
        defaults.set(recent, forKey: "quickActions.recent")
    }
    func results(_ actions: [QuickAction], query: String) -> [QuickAction] {
        actions.enumerated().compactMap { offset, action -> (Int, QuickAction, Int)? in
            guard let rank = action.matchRank(query) else { return nil }
            return (offset, action, rank)
        }.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            let lf = favorites.contains(lhs.1.id), rf = favorites.contains(rhs.1.id)
            if lf != rf { return lf }
            let lr = recent.firstIndex(of: lhs.1.id) ?? Int.max
            let rr = recent.firstIndex(of: rhs.1.id) ?? Int.max
            if lr != rr { return lr < rr }
            return lhs.0 < rhs.0
        }.map { $0.1 }
    }
}

/// Maps normalized text and pinyin back to original UTF-16 ranges for AppKit.
/// Constructed once per action, not while rendering each keystroke.
private struct QuickActionHighlightIndex {
    private var plain = "", latin = "", initials = ""
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
