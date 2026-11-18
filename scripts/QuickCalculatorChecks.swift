import Foundation
@main struct Checks {
    static func main() {
        let cases = ["12*(3+4)": "84", "0.1+0.2": "0.3", "200*15%": "30",
                     "-2^2": "-4", "(-2)^2": "4", "2^3^2": "512", "2^-3": "0.125",
                     "１＋２×３": "7", "12÷4=": "3", ".5+1.25": "1.75", "1e3+2": "1002",
                     "1-1": "0", "200*(1+15%)": "230"]
        for (expression, expected) in cases {
            guard case .success(let actual) = QuickCalculator.evaluate(expression), actual == expected else { fatalError(expression) }
        }
        for expression in ["1/0", "1+", "(1+2", "1..2+3", "2^99999", "1 2+3", "1+="] {
            guard case .failure = QuickCalculator.evaluate(expression) else { fatalError(expression) }
        }
        for query in ["微信", "1700000000000", "{\"a\":1}", "awake 30", "1+system()", String(repeating:"1+",count:200)] {
            precondition(QuickCalculator.evaluate(query) == nil, query)
        }
        print("PASS: precedence, decimals, percentages, powers, Unicode, invalid inputs and search isolation")
    }
}
