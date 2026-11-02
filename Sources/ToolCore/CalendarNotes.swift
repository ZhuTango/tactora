import Foundation

struct CalendarNote: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var completed: Bool
}

/// Date-only keys deliberately keep a note on its chosen calendar day when the time zone changes.
@MainActor
final class CalendarNotesStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tactora/Calendar/notes.json")
    }
    private struct Document: Codable {
        var version = 1
        var days: [String: [CalendarNote]] = [:]
    }
    private var document = Document()
    private let fileURL: URL?
    private(set) var loadError: Error?
    // Unsubmitted input survives date changes and reopening the popover in this app session.
    var drafts: [String: String] = [:]
    var draftEditingIDs: [String: UUID] = [:]
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard decoded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            document = decoded
        } catch { loadError = error }
    }
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func entries(on day: String) -> [CalendarNote] { document.days[day] ?? [] }
    func add(_ text: String, on day: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var next = document
        next.days[day, default: []].append(CalendarNote(id: UUID(), text: text, completed: false))
        try save(next)
    }
    func update(_ id: UUID, text: String, completed: Bool, on day: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = document.days[day]?.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        next.days[day]![index].text = text
        next.days[day]![index].completed = completed
        try save(next)
    }
    func remove(_ id: UUID, on day: String) throws {
        var next = document
        next.days[day]?.removeAll { $0.id == id }
        if next.days[day]?.isEmpty == true { next.days.removeValue(forKey: day) }
        try save(next)
    }
    private func save(_ next: Document) throws {
        if let loadError { throw loadError }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        }
        document = next
    }
}
