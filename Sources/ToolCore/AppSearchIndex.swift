import Foundation

/// Cached per app, so typing never repeatedly transliterates the application inventory.
struct AppSearchIndex {
    let source: String
    private let plain: String
    private let full: String
    private let initials: String

    init(source: String) {
        self.source = source
        plain = Self.fold(source)
        let latin = Self.fold(source.applyingTransform(.mandarinToLatin, reverse: false) ?? source)
        let syllables = latin.split { !$0.isLetter && !$0.isNumber }
        full = syllables.joined()
        initials = String(syllables.compactMap(\.first))
    }

    func matches(_ query: String) -> Bool {
        Self.fold(query).split(whereSeparator: { $0.isWhitespace }).allSatisfy { token in
            if plain.contains(token) { return true }
            guard token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
            return full.contains(token) || initials.contains(token)
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
