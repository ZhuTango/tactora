import Foundation

enum TextOperation: String, CaseIterable {
    case trim, joinLines, removeEmptyLines, deduplicateLines, uppercase, lowercase
}

enum TextProcessingError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "内容超过处理上限，请缩短输入 / Content exceeds the processing limit." }
}

enum TextProcessor {
    static let maximumBytes = 1_048_576

    static func process(_ input: String, operation: TextOperation) throws -> String {
        guard input.utf8.count <= maximumBytes else { throw TextProcessingError.tooLarge }
        switch operation {
        case .trim: return input.trimmingCharacters(in: .whitespacesAndNewlines)
        case .uppercase: return input.uppercased()
        case .lowercase: return input.lowercased()
        case .joinLines, .removeEmptyLines, .deduplicateLines:
            let lines = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            switch operation {
            case .joinLines:
                return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            case .removeEmptyLines:
                return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            case .deduplicateLines:
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
            default: preconditionFailure("Handled above")
            }
        }
    }
}
