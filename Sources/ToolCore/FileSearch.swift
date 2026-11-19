import Foundation

struct IndexedFile: Codable, Equatable {
    let path: String
    let directory: Bool
    let modified: Date
    var name: String { (path as NSString).lastPathComponent }
}

struct FileSearchQuery {
    let terms: [String]
    let ext: String?
    let foldersOnly: Bool
    init(_ input: String) {
        let tokens = Self.fold(input).split(whereSeparator: \.isWhitespace).map(String.init)
        ext = tokens.first(where: { $0.hasPrefix("ext:") }).map { String($0.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        foldersOnly = tokens.contains("type:folder") || tokens.contains("type:目录")
        terms = tokens.filter { !$0.hasPrefix("ext:") && !$0.hasPrefix("type:") }
    }
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct FileSearchCatalog {
    private struct Phonetics {
        let latin: String
        let initials: String
        let boundaries: Set<Int>

        func wholeSyllables(_ token: String) -> Bool {
            let text = latin as NSString
            var start = 0
            while start < text.length {
                let hit = text.range(of: token, options: .literal, range: NSRange(location: start, length: text.length - start))
                guard hit.location != NSNotFound else { return false }
                if boundaries.contains(hit.location), boundaries.contains(NSMaxRange(hit)) { return true }
                start = hit.location + 1
            }
            return false
        }
    }
    private struct Row {
        var file: IndexedFile
        let name: String
        let path: String
        let ext: String
        let phonetics: Phonetics?
    }
    private var rows: [String: Row] = [:]
    init(_ files: [IndexedFile]) {
        update(files, removing: [])
    }
    mutating func update(_ files: [IndexedFile], removing paths: [String]) {
        for path in paths { rows.removeValue(forKey: path) }
        var keys = [String: Phonetics]()
        for file in files {
            if rows[file.path] != nil {
                rows[file.path]?.file = file
                continue
            }
            let name = FileSearchQuery.fold(file.name)
            var phonetics = keys[name]
            if phonetics == nil, name.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                let index = QuickActionHighlightIndex(name)
                phonetics = Phonetics(latin: index.latin, initials: index.initials, boundaries: index.syllableBoundaries)
                keys[name] = phonetics
            }
            rows[file.path] = Row(file: file, name: name, path: FileSearchQuery.fold(file.path),
                                  ext: FileSearchQuery.fold((file.path as NSString).pathExtension), phonetics: phonetics)
        }
    }
    func search(_ input: String, limit: Int = 80) -> [IndexedFile] {
        guard input.count <= 256 else { return [] }
        let query = FileSearchQuery(input)
        guard limit > 0 else { return [] }
        var matches: [(Int, IndexedFile)] = []
        func better(_ a: (Int, IndexedFile), _ b: (Int, IndexedFile)) -> Bool {
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.modified != b.1.modified { return a.1.modified > b.1.modified }
            return a.1.path < b.1.path
        }
        // Keep only the best results; broad searches must not sort the entire index.
        func insert(_ candidate: (Int, IndexedFile)) {
            if matches.count < limit {
                matches.append(candidate)
                var child = matches.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard better(matches[parent], matches[child]) else { break }
                    matches.swapAt(parent, child); child = parent
                }
            } else if better(candidate, matches[0]) {
                matches[0] = candidate
                var parent = 0
                while parent * 2 + 1 < matches.count {
                    var child = parent * 2 + 1
                    if child + 1 < matches.count && better(matches[child], matches[child + 1]) { child += 1 }
                    guard better(matches[parent], matches[child]) else { break }
                    matches.swapAt(parent, child); parent = child
                }
            }
        }
        let phrase = query.terms.joined(separator: " ")
        for row in rows.values {
            if query.foldersOnly && !row.file.directory { continue }
            if let ext = query.ext, row.file.directory || ext != row.ext { continue }
            let rank: Int
            if row.name == phrase { rank = 0 }
            else if row.name.hasPrefix(phrase) || row.phonetics?.initials.hasPrefix(phrase) == true { rank = 1 }
            else if query.terms.allSatisfy({ row.name.contains($0) }) { rank = 2 }
            else if let keys = row.phonetics, query.terms.allSatisfy({ row.name.contains($0) || keys.wholeSyllables($0) }) { rank = 2 }
            else if let keys = row.phonetics, query.terms.allSatisfy({
                row.name.contains($0) || keys.latin.contains($0) || keys.initials.contains($0)
            }) { rank = 3 }
            else if query.terms.allSatisfy({ term in
                row.path.contains(term) || row.phonetics?.latin.contains(term) == true || row.phonetics?.initials.contains(term) == true
            }) { rank = 4 }
            else { continue }
            insert((rank, row.file))
        }
        return matches.sorted(by: better).map { $0.1 }
    }
}

/// File names and metadata only; never opens file contents or follows symbolic links.
enum FileSearchScanner {
    static let excluded = Set(["node_modules", ".git", ".build", "DerivedData", "Pods", "__pycache__", "Library", "local.tango.macbglive"])
    static let capacity = 200_000
    struct Scan { var files: [IndexedFile] = []; var unavailable: [String] = []; var limited = false }
    // FSEvents uses /private paths even after deletion, when resolvingSymlinks cannot resolve them.
    static func canonicalPath(_ raw: String) -> String {
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        for prefix in ["/private/var", "/private/tmp", "/private/etc"] {
            if path == prefix || path.hasPrefix(prefix + "/") { return String(path.dropFirst("/private".count)) }
        }
        return path
    }
    static func contains(_ path: String, in root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    static func roots(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in Set(paths.map { canonicalPath(URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path) }).sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            if !result.contains(where: { contains(path, in: $0) }) { result.append(path) }
        }
        return result
    }
    static func scan(_ roots: [String], includingEntries entries: Set<String> = [], excluding exclusions: [String] = [], limit: Int = capacity, cancelled: () -> Bool = { false }) -> Scan {
        var output = Scan()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey]
        // Visit each scope and its immediate children before descending into large subtrees.
        let blocked = Set(exclusions)
        var level: [URL] = []
        for root in roots where !exclusions.contains(where: { contains(root, in: $0) }) {
            let url = URL(fileURLWithPath: root)
            if entries.contains(root) {
                guard let meta = try? url.resourceValues(forKeys: keys), meta.isSymbolicLink != true,
                      let directory = meta.isDirectory else { continue }
                if output.files.count >= limit { output.limited = true; break }
                output.files.append(IndexedFile(path: root, directory: directory, modified: meta.contentModificationDate ?? .distantPast))
                if !directory || meta.isPackage == true { continue }
            }
            level.append(url)
        }
        while !level.isEmpty {
            var next: [URL] = []
            for directory in level {
                if cancelled() { return output }
                guard let metadata = try? directory.resourceValues(forKeys: keys),
                      metadata.isSymbolicLink != true, metadata.isDirectory == true,
                      let children = try? FileManager.default.contentsOfDirectory(at: directory,
                          includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else {
                    if output.unavailable.count < 20 { output.unavailable.append(directory.path) }
                    continue
                }
                for child in children {
                    if cancelled() { return output }
                    guard !excluded.contains(child.lastPathComponent), !blocked.contains(canonicalPath(child.path)),
                          let meta = try? child.resourceValues(forKeys: keys), meta.isSymbolicLink != true else { continue }
                    if output.files.count >= limit { output.limited = true; return output }
                    let isDirectory = meta.isDirectory == true
                    output.files.append(IndexedFile(path: canonicalPath(child.path), directory: isDirectory, modified: meta.contentModificationDate ?? .distantPast))
                    if isDirectory && meta.isPackage != true { next.append(child) }
                }
            }
            level = next
        }
        return output
    }
}
