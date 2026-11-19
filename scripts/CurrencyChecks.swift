import Foundation
@main struct CurrencyChecks {
    @MainActor static func main() async throws {
        let suite = "currency.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for input in ["100 USD CNY", "100 usd to cny", "100美元兑人民币", "１００美元换算成人民币", "100USD→RMB"] {
            precondition(CurrencyQuery.parse(input) == CurrencyQuery(amount: 100, from: "USD", to: "CNY"), input)
        }
        for input in ["微信", "12*(3+4)", "100 USD", "NaN USD CNY", "100 USD CNY x", "1,00 USD CNY"] {
            precondition(CurrencyQuery.parse(input) == nil, input)
        }
        for input in ["100", "0.5", "-20", "１００", ".5"] { precondition(CurrencyQuery.suggestion(input) != nil) }
        for input in ["", "微信", "1+2", "100 USD", "1,00", "1."] { precondition(CurrencyQuery.suggestion(input) == nil) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let data = Data("{\"date\":\"\(date)\",\"base\":\"EUR\",\"rates\":{\"USD\":1.2,\"CNY\":8.4}}".utf8)
        var requests = 0
        let rates = CurrencyRates(defaults: defaults, fetch: { requests += 1; return data })
        precondition(CurrencyRates.amount(123.456, currency: "CNY") == "123.46")
        precondition(CurrencyRates.amount(123.456, currency: "JPY") == "123")
        precondition(CurrencyRates.amount(-0.001, currency: "CNY") == "0.00")
        let query = CurrencyQuery.parse("100 USD CNY")!
        let quote = try await rates.quote(query)
        precondition(quote.value == "700.00" && quote.rate == "7" && !quote.cached)
        _ = try await rates.quote(CurrencyQuery.parse("200 USD CNY")!)
        precondition(requests == 1, "Amounts reuse cached rates")
        let same = try await rates.quote(CurrencyQuery.parse("100 USD USD")!)
        precondition(same.value == "100.00" && requests == 1)
        do { _ = try await rates.quote(CurrencyQuery.parse("100 TWD CNY")!); fatalError("Unsupported currency") }
        catch CurrencyRates.Failure.unsupported { }
        let persisted = CurrencyRates(defaults: defaults, fetch: { fatalError("Fresh persisted cache should be reused") })
        let saved = try await persisted.quote(query)
        precondition(saved.value == "700.00")
        let snapshot = try JSONDecoder().decode(CurrencyRates.Snapshot.self, from: data)
        defaults.set(try JSONEncoder().encode(CurrencyRates.Cache(snapshot: snapshot, fetched: Date().addingTimeInterval(-86400))), forKey: "quickActions.currencyRates.v1")
        let offline = CurrencyRates(defaults: defaults, fetch: { throw URLError(.notConnectedToInternet) })
        let fallback = try await offline.quote(query)
        precondition(fallback.cached)
        defaults.removePersistentDomain(forName: suite)
        let missing = CurrencyRates(defaults: defaults, fetch: { throw URLError(.notConnectedToInternet) })
        do { _ = try await missing.quote(query); fatalError("Offline without cache") } catch CurrencyRates.Failure.unavailable { }
        defaults.set(try JSONEncoder().encode(CurrencyRates.Cache(snapshot: snapshot, fetched: Date().addingTimeInterval(-8 * 86400))), forKey: "quickActions.currencyRates.v1")
        let expired = CurrencyRates(defaults: defaults, fetch: { throw URLError(.notConnectedToInternet) })
        do { _ = try await expired.quote(query); fatalError("Expired cache") } catch CurrencyRates.Failure.unavailable { }
        defaults.removePersistentDomain(forName: suite)
        let malformed = CurrencyRates(defaults: defaults, fetch: { Data("{\"date\":\"invalid\",\"base\":\"EUR\",\"rates\":{\"USD\":0}}".utf8) })
        do { _ = try await malformed.quote(query); fatalError("Invalid rate accepted") } catch CurrencyRates.Failure.unavailable { }
        if CommandLine.arguments.contains("--live") {
            let live = try await CurrencyRates(defaults: defaults).quote(query)
            print("LIVE: 100 USD = \(live.value) CNY · \(live.date)")
        }
        print("PASS: currency aliases, parsing, cross rates, amount privacy, persistent cache, offline fallback and unsupported currencies")
    }
}
