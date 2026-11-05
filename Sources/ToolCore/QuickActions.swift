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

    init(id: String, title: String, detail: String = "", keywords: String = "", symbol: String = "command", destination: Destination) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.destination = destination
        index = AppSearchIndex(source: title + " " + keywords)
    }

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
