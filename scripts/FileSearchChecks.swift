import Foundation
@main struct Checks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-search-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func create(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        try create("项目/合同.pdf"); try create("其他/合同.pdf"); try create("项目/合同.txt")
        try create("node_modules/ignore.txt"); try create(".hidden/secret.txt"); try create("Demo.app/Contents/private.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let paths = FileSearchScanner.roots([root.path, root.appendingPathComponent("项目").path, root.path])
        precondition(paths == [root.path])
        let scan = FileSearchScanner.scan(paths)
        precondition(!scan.limited && scan.unavailable.isEmpty)
        precondition(!scan.files.contains { $0.path.contains("ignore") || $0.path.contains("secret") || $0.path.contains("Contents") || $0.name == "loop" })
        let catalog = FileSearchCatalog(scan.files)
        precondition(catalog.search("合同 ext:pdf").count == 2)
        precondition(catalog.search("项目 合同 ext:pdf").count == 1)
        precondition(catalog.search("项目 type:folder").allSatisfy(\.directory))
        precondition(catalog.search("not-found").isEmpty)
        precondition(FileSearchScanner.scan(paths, limit: 1).limited)
        let old = root.appendingPathComponent("项目/合同.txt"), new = root.appendingPathComponent("项目/改名.txt")
        try FileManager.default.moveItem(at: old, to: new)
        var updated = FileSearchCatalog(FileSearchScanner.scan(paths).files)
        precondition(updated.search("改名").count == 1 && updated.search("合同 ext:txt").isEmpty)
        try FileManager.default.removeItem(at: new)
        updated = FileSearchCatalog(FileSearchScanner.scan(paths).files)
        precondition(updated.search("改名").isEmpty)
        precondition(!FileSearchScanner.contains(root.path + "-other/a", in: root.path))
        precondition(!FileSearchScanner.scan([root.appendingPathComponent("missing").path]).unavailable.isEmpty)
        let synthetic = (0..<100_000).map { IndexedFile(path: "/test/folder\($0 % 100)/file\($0).pdf", directory: false, modified: .distantPast) }
        let large = FileSearchCatalog(synthetic); let start = Date()
        precondition(large.search("file99999 ext:pdf").count == 1)
        let expected = synthetic.sorted { $0.path < $1.path }.prefix(80).map(\.path)
        precondition(large.search("").map(\.path) == expected, "Bounded ranking matches full sort")
        precondition(FileSearchScanner.canonicalPath("/private/var/deleted/name") == "/var/deleted/name")
        print("PASS: exclusions, symlinks, scopes, filename/path/type search, rename/delete, cap; 100k search \(Date().timeIntervalSince(start) * 1000) ms")
    }
}
