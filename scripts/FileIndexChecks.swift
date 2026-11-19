import AppKit
@main struct Checks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-live-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "index.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let first = scope.appendingPathComponent("first.txt")
        try Data("test".utf8).write(to: first)
        let cache = root.appendingPathComponent("cache.json")
        let index = FileSearchIndex(defaults: defaults, cacheURL: cache, roots: [scope.path])
        func results(_ query: String) async -> [IndexedFile] {
            await withCheckedContinuation { continuation in index.search(query) { files, _ in continuation.resume(returning: files) } }
        }
        func wait(_ query: String, count: Int) async throws {
            for _ in 0..<120 {
                if await results(query).count == count && !index.state.scanning { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            fatalError("Index timeout: \(query), expected \(count), state \(index.state)")
        }
        try await wait("first.txt", count: 1)
        precondition(index.state.watching)
        let added = scope.appendingPathComponent("added.txt")
        try Data("new".utf8).write(to: added)
        try await wait("added.txt", count: 1)
        let renamed = scope.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: added, to: renamed)
        try await wait("renamed.txt", count: 1)
        let old = await results("added.txt"); precondition(old.isEmpty)
        try FileManager.default.removeItem(at: renamed)
        try await wait("renamed.txt", count: 0)
        precondition(FileManager.default.fileExists(atPath: cache.path))
        index.setRoots([])
        try await wait("first.txt", count: 0)
        for _ in 0..<30 {
            if !index.state.watching { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(!index.state.watching && index.state.roots.isEmpty)
        print("PASS: actual FSEvents add/rename/delete, cache storage and removing scopes stops watching")
    }
}
