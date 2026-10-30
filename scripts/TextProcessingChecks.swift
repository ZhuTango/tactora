import Foundation

@main struct TextProcessingChecks {
    static func expect(_ text: String, _ operation: TextOperation, _ expected: String) throws {
        let actual = try TextProcessor.process(text, operation: operation)
        precondition(actual == expected, "\(operation): expected \(String(reflecting: expected)); got \(String(reflecting: actual))")
    }
    static func main() throws {
        try expect(" \t方寸\n  Tactora  \n", .trim, "方寸\n  Tactora")
        try expect("one\r\ntwo\rthree\n\n四", .joinLines, "one two three 四")
        try expect("a\n \t\n\nb\n", .removeEmptyLines, "a\nb")
        try expect("乙\n甲\n乙\n甲 \n甲\n", .deduplicateLines, "乙\n甲\n甲 \n")
        try expect("Tactora 中文 123", .uppercase, "TACTORA 中文 123")
        try expect("TACTORA 中文 123", .lowercase, "tactora 中文 123")
        try expect("a\r\nb\r\na", .deduplicateLines, "a\nb")
        for operation in TextOperation.allCases { try expect("", operation, "") }
        do { _ = try TextProcessor.process(String(repeating: "字", count: TextProcessor.maximumBytes), operation: .trim); fatalError("Oversized Unicode input accepted") }
        catch TextProcessingError.tooLarge { }
        let original = " a\n a \n"
        _ = try TextProcessor.process(original, operation: .deduplicateLines)
        precondition(original == " a\n a \n")
        print("PASS: six text operations, stable exact deduplication, CRLF/CR, Unicode, empty input, byte limit and original preservation")
    }
}
