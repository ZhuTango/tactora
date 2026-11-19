import Foundation

struct CurrencyQuery: Equatable {
    let amount: Double
    let from: String
    let to: String
    private static let aliases = ["美元": "USD", "美金": "USD", "人民币": "CNY", "元": "CNY", "RMB": "CNY",
        "欧元": "EUR", "英镑": "GBP", "日元": "JPY", "日币": "JPY", "港币": "HKD", "港元": "HKD",
        "澳元": "AUD", "澳币": "AUD", "加元": "CAD", "新加坡元": "SGD", "新币": "SGD", "韩元": "KRW",
        "瑞郎": "CHF", "新西兰元": "NZD", "泰铢": "THB", "台币": "TWD", "新台币": "TWD"]
    static func completion(amount: String, english: Bool) -> (text: String, selection: NSRange) {
        let source = english ? "USD" : "美元"
        let text = amount + " " + source + (english ? " to CNY" : "兑人民币")
        return (text, NSRange(location: amount.utf16.count + 1, length: source.utf16.count))
    }
    static func suggestion(_ input: String) -> String? {
        let number = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        guard number.count <= 32,
              number.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(number), value.isFinite, abs(value) <= 1e15 else { return nil }
        return number
    }
    static func parse(_ input: String) -> CurrencyQuery? {
        guard input.count <= 128 else { return nil }
        var text = input.folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX")).uppercased()
        for alias in aliases.keys.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: alias, with: aliases[alias]!)
        }
        let pattern = #"^\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*([A-Z]{3})\s*(?:TO|IN|兑|换|转|兑换|换算成|->|→|=)?\s*([A-Z]{3})\s*$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let f = Range(match.range(at: 2), in: text), let t = Range(match.range(at: 3), in: text),
              let amount = Double(text[a]), amount.isFinite, abs(amount) <= 1e15 else { return nil }
        return CurrencyQuery(amount: amount, from: String(text[f]), to: String(text[t]))
    }
}

@MainActor
final class CurrencyRates {
    struct Snapshot: Codable {
        let date: String
        let base: String
        let rates: [String: Double]
    }
    struct Cache: Codable { let snapshot: Snapshot; let fetched: Date }
    struct Quote {
        let value: String
        let rate: String
        let date: String
        let cached: Bool
    }
    enum Failure: Error { case unavailable, unsupported, invalid }
    private let defaults: UserDefaults
    private let fetch: () async throws -> Data
    private var cache: Cache?
    private static let key = "quickActions.currencyRates.v1"
    private static let supported = Set("AUD BRL CAD CHF CNY CZK DKK EUR GBP HKD HUF IDR ILS INR ISK JPY KRW MXN MYR NOK NZD PHP PLN RON SEK SGD THB TRY USD ZAR".split(separator: " ").map(String.init))
    init(defaults: UserDefaults = .standard, fetch: (() async throws -> Data)? = nil) {
        self.defaults = defaults
        self.fetch = fetch ?? {
            var request = URLRequest(url: URL(string: "https://api.frankfurter.dev/v1/latest?base=EUR")!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64_000 else { throw Failure.unavailable }
            return data
        }
        if let data = defaults.data(forKey: Self.key), let value = try? JSONDecoder().decode(Cache.self, from: data), Self.valid(value.snapshot) { cache = value }
    }
    private static func valid(_ snapshot: Snapshot) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: snapshot.date), formatter.string(from: date) == snapshot.date,
              date <= Date().addingTimeInterval(86_400), snapshot.base == "EUR", !snapshot.rates.isEmpty else { return false }
        return snapshot.rates.allSatisfy { $0.value.isFinite && $0.value > 0 }
    }
    func quote(_ query: CurrencyQuery) async throws -> Quote {
        guard Self.supported.contains(query.from), Self.supported.contains(query.to) else { throw Failure.unsupported }
        if query.from == query.to { return Quote(value: Self.amount(query.amount, currency: query.to), rate: "1", date: "", cached: false) }
        var stale = false
        if cache == nil || Date().timeIntervalSince(cache!.fetched) >= 6 * 3600 || cache!.fetched > Date() {
            do {
                let data = try await fetch()
                try Task.checkCancellation()
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard Self.valid(snapshot) else { throw Failure.invalid }
                let value = Cache(snapshot: snapshot, fetched: Date())
                cache = value
                defaults.set(try JSONEncoder().encode(value), forKey: Self.key)
            } catch {
                try Task.checkCancellation()
                guard let cache, (0...7 * 86400).contains(Date().timeIntervalSince(cache.fetched)) else { throw Failure.unavailable }
                stale = true
            }
        }
        guard let snapshot = cache?.snapshot,
              let source = query.from == "EUR" ? 1 : snapshot.rates[query.from],
              let target = query.to == "EUR" ? 1 : snapshot.rates[query.to] else { throw Failure.unsupported }
        let rate = target / source
        let amount = query.amount * rate
        guard amount.isFinite else { throw Failure.invalid }
        return Quote(value: Self.amount(amount, currency: query.to), rate: Self.format(rate), date: snapshot.date, cached: stale)
    }
    static func amount(_ number: Double, currency: String) -> String {
        let digits = ["JPY", "KRW", "ISK"].contains(currency) ? 0 : 2
        let rounded = number.rounded() == 0 && abs(number) < (digits == 0 ? 0.5 : 0.005) ? 0 : number
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, rounded)
    }
    static func format(_ number: Double) -> String {
        number == 0 ? "0" : String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), number)
    }
}
