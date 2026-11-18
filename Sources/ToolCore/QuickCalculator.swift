import Foundation

/// A bounded arithmetic grammar; never evaluates scripts or system expressions.
enum QuickCalculator {
    enum Failure: Error { case invalid, divisionByZero, outOfRange }

    static func evaluate(_ query: String) -> Result<String, Failure>? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        guard text.count <= 256, text.contains(where: { $0.isNumber }),
              text.contains(where: { "+-*/^%=".contains($0) }),
              text.allSatisfy({ "0123456789.eE+-*/^%()= ".contains($0) || $0.isWhitespace }) else { return nil }
        var expression = text
        if expression.last == "=" { expression.removeLast() }
        var parser = Parser(input: Array(expression))
        do {
            let value = try parser.sum()
            parser.skipSpaces()
            guard parser.position == parser.input.count else { throw Failure.invalid }
            guard value.isFinite else { throw Failure.outOfRange }
            return .success(value == 0 ? "0" : String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value))
        } catch let error as Failure { return .failure(error) }
        catch { return .failure(.invalid) }
    }

    private struct Parser {
        let input: [Character]
        var position = 0
        mutating func skipSpaces() { while position < input.count && input[position].isWhitespace { position += 1 } }
        mutating func take(_ character: Character) -> Bool {
            skipSpaces()
            guard position < input.count, input[position] == character else { return false }
            position += 1
            return true
        }
        mutating func sum() throws -> Double {
            var value = try product()
            while true {
                if take("+") { value += try product() }
                else if take("-") { value -= try product() }
                else { return value }
            }
        }
        mutating func product() throws -> Double {
            var value = try unary()
            while true {
                if take("*") { value *= try unary() }
                else if take("/") {
                    let divisor = try unary()
                    guard divisor != 0 else { throw Failure.divisionByZero }
                    value /= divisor
                } else { return value }
            }
        }
        mutating func unary() throws -> Double {
            if take("+") { return try unary() }
            if take("-") { return try -unary() }
            return try power()
        }
        mutating func power() throws -> Double {
            var value = try primary()
            while take("%") { value /= 100 }
            if take("^") { value = pow(value, try unary()) }
            guard value.isFinite else { throw Failure.outOfRange }
            return value
        }
        mutating func primary() throws -> Double {
            if take("(") {
                let value = try sum()
                guard take(")") else { throw Failure.invalid }
                return value
            }
            skipSpaces()
            let start = position
            while position < input.count && (input[position].isNumber || input[position] == ".") { position += 1 }
            if position < input.count && (input[position] == "e" || input[position] == "E") {
                position += 1
                if position < input.count && (input[position] == "+" || input[position] == "-") { position += 1 }
                while position < input.count && input[position].isNumber { position += 1 }
            }
            guard position > start, let value = Double(String(input[start..<position])), value.isFinite else { throw Failure.invalid }
            return value
        }
    }
}
