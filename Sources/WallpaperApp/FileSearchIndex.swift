import AppKit
import CoreServices

/// Index mutations and filesystem events run on one utility queue; searches use immutable snapshots.
final class FileSearchIndex: @unchecked Sendable {
    static let shared = FileSearchIndex()
    static let changed = Notification.Name("TactoraFileSearchIndexChanged")
    struct State {
        var roots: [String] = []
        var count = 0
        var scanning = false
        var limited = false
        var unavailable: [String] = []
        var watching = false
    }
    private struct Saved: Codable { let version: Int; let roots: [String]; let files: [IndexedFile] }
    private let worker = DispatchQueue(label: "Tactora.file-index", qos: .utility)
    private let searchQueue = DispatchQueue(label: "Tactora.file-search", qos: .userInitiated)
    private let lock = NSLock()
    private var stateValue = State()
    private var catalog = FileSearchCatalog([])
    private var epoch = 0
    private var files: [String: IndexedFile] = [:]
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var dirty = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let cacheURL: URL
    private let watch: Bool
    var state: State { lock.lock(); defer { lock.unlock() }; return stateValue }
    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, roots: [String]? = nil, watch: Bool = true) {
        self.defaults = defaults
        self.watch = watch
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.tango.macbglive/file-index-v1.json")
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateValue.roots = FileSearchScanner.roots(roots ?? defaults.stringArray(forKey: "fileSearch.roots.v1") ?? ["Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0).path })
        if watch {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
            }
        }
        let initial = stateValue.roots
        worker.async { [weak self] in
            guard let self else { return }
            if let data = try? Data(contentsOf: self.cacheURL), data.count < 100_000_000,
               let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1, saved.roots == initial,
               saved.files.count <= FileSearchScanner.capacity {
                self.files = Dictionary(saved.files.filter { file in initial.contains { FileSearchScanner.contains(file.path, in: $0) } }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.publish(scanning: true)
            }
            self.scan(initial, full: true, token: 0)
        }
    }
    deinit {
        pending?.cancel(); pendingSave?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func setRoots(_ roots: [String]) {
        let paths = FileSearchScanner.roots(roots)
        defaults.set(paths, forKey: "fileSearch.roots.v1")
        lock.lock(); stateValue.roots = paths; epoch += 1; let token = epoch; catalog = FileSearchCatalog([]); stateValue.count = 0; lock.unlock()
        worker.async { [weak self] in self?.scan(paths, full: true, token: token) }
    }
    func rebuild() {
        lock.lock(); epoch += 1; let token = epoch; let roots = stateValue.roots; lock.unlock()
        worker.async { [weak self] in self?.scan(roots, full: true, token: token) }
    }
    private func current(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return epoch == token }
    private func publish(scanning: Bool, unavailable: [String]? = nil, limited: Bool? = nil, token: Int? = nil) {
        let next = FileSearchCatalog(Array(files.values))
        lock.lock()
        if let token, epoch != token { lock.unlock(); return }
        catalog = next; stateValue.count = files.count; stateValue.scanning = scanning
        if let unavailable { stateValue.unavailable = unavailable }
        if let limited { stateValue.limited = limited }
        stateValue.watching = stream != nil
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    private func scan(_ paths: [String], full: Bool, token: Int) {
        guard current(token) else { return }
        if full { pending?.cancel(); dirty.removeAll(); startWatcher(paths) }
        publish(scanning: true, token: token)
        let retained = full ? [:] : files.filter { file in !paths.contains { FileSearchScanner.contains(file.key, in: $0) } }
        let scanned = FileSearchScanner.scan(paths, limit: max(0, FileSearchScanner.capacity - retained.count), cancelled: { !self.current(token) })
        guard current(token) else { return }
        files = retained
        for file in scanned.files { files[file.path] = file }
        publish(scanning: false, unavailable: (full ? [] : state.unavailable.filter { problem in !paths.contains { FileSearchScanner.contains(problem, in: $0) } }) + scanned.unavailable, limited: scanned.limited || (!full && state.limited), token: token)
        pendingSave?.cancel()
        if full { saveCache(token: token) }
        else {
            let save = DispatchWorkItem { [weak self] in self?.saveCache(token: token) }
            pendingSave = save
            worker.asyncAfter(deadline: .now() + 5, execute: save)
        }
    }
    private func saveCache(token: Int) {
        lock.lock()
        guard epoch == token else { lock.unlock(); return }
        let roots = stateValue.roots
        lock.unlock()
        let saved = Saved(version: 1, roots: roots, files: Array(files.values))
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* The in-memory index remains usable if cache storage fails. */ }
    }
    func search(_ text: String, completion: @escaping ([IndexedFile], State) -> Void) {
        lock.lock(); let snapshot = catalog; let state = stateValue; lock.unlock()
        searchQueue.async {
            let result = snapshot.search(text)
            DispatchQueue.main.async { completion(result, state) }
        }
    }
    private func startWatcher(_ roots: [String]) {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        guard watch, !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let index = Unmanaged<FileSearchIndex>.fromOpaque(info).takeUnretainedValue()
            let strings = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let resetFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            if (0..<count).contains(where: { flags[$0] & resetFlags != 0 }) { index.rebuild(); return }
            index.handleChanges(strings)
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, worker)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    private func handleChanges(_ paths: [String]) {
        let roots = state.roots
        for rawPath in paths {
            let path = FileSearchScanner.canonicalPath(rawPath)
            guard let root = roots.first(where: { FileSearchScanner.contains(path, in: $0) }) else { continue }
            // Ignore excluded descendants, including compiler/build churn.
            let relative = String(path.dropFirst(root.count)).split(separator: "/").map(String.init)
            if relative.contains(where: { $0.hasPrefix(".") || FileSearchScanner.excluded.contains($0) || ["app", "bundle", "framework"].contains(($0 as NSString).pathExtension) }) { continue }
            let parent = (path as NSString).deletingLastPathComponent
            dirty.insert(FileSearchScanner.contains(parent, in: root) ? parent : root)
        }
        guard !dirty.isEmpty else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = FileSearchScanner.roots(Array(self.dirty)); self.dirty.removeAll()
            self.lock.lock(); let token = self.epoch; self.lock.unlock()
            self.scan(paths.count > 64 ? self.state.roots : paths, full: false, token: token)
        }
        pending = work
        worker.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}
