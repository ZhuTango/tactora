import AppKit
import UniformTypeIdentifiers

@MainActor
final class WallpaperController {
    private let store: DisplayConfigurationStore
    private let connected: @MainActor () -> [DisplayTarget]
    private var revision = 0
    private var rotationTimer: Timer?
    private var deadlines: [String: Date] = [:]
    private var rotating = false
    private var terminated = false
    private(set) var featureEnabled = true
    deinit { rotationTimer?.invalidate() }
    private let cache: VideoCache
    private var automaticallyPauseWhenOccluded: Bool
    private(set) var preparing: Set<String> = []
    private(set) var configurations: [String: DisplayConfiguration]
    private(set) var displays: [DisplayTarget] = []
    private(set) var groups: [String: WallpaperEngine] = [:]
    private(set) var errors: [String: String] = [:]
    var onChange: (() -> Void)?
    var policy = PlaybackPolicy() {
        didSet {
            for engine in groups.values { engine.policy = policy }
            scheduleRotation()
            onChange?()
        }
    }

    init(store: DisplayConfigurationStore = .applicationStore,
         cache: VideoCache = .shared, automaticallyPauseWhenOccluded: Bool = true,
         connected: @escaping @MainActor () -> [DisplayTarget] = { DisplayTarget.connected() }) throws {
        self.store = store
        self.cache = cache
        self.automaticallyPauseWhenOccluded = automaticallyPauseWhenOccluded
        self.connected = connected
        configurations = try store.load()
    }

    // Import the old all-screen video only once, after an atomic save succeeds.
    func migrateLegacy(defaults: UserDefaults) throws {
        guard !store.exists, let path = defaults.string(forKey: "videoPath") else { return }
        let targets = connected()
        guard !targets.isEmpty else { return }
        let records = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, DisplayConfiguration(name: $0.name, path: path, kind: .video,
                                        stopped: defaults.bool(forKey: "videoStopped")))
        })
        try store.save(records)
        configurations = records
        defaults.removeObject(forKey: "videoPath")
        defaults.removeObject(forKey: "videoStopped")
    }

    func refreshDisplays() async {
        guard featureEnabled, !terminated, !Task.isCancelled else { return }
        let previousIDs = Set(displays.map(\.id))
        displays = connected()
        for display in displays where !previousIDs.contains(display.id) {
            guard let config = configurations[display.id], config.kind == .photo else { continue }
            do {
                try WallpaperEngine(screens: [display.screen]).setPhoto(config.url)
                errors.removeValue(forKey: display.id)
            } catch { errors[display.id] = error.localizedDescription }
        }
        await rebuildPlayback()
    }

    func select(_ url: URL, kind: DisplayConfiguration.Kind, for id: String,
                playlist: [WallpaperItem]? = nil, interval: TimeInterval? = nil, index: Int = 0,
                rotationEnabled: Bool = true) async throws {
        let previous = configurations[id]
        if kind == .video { try await WallpaperEngine.validateVideo(url) }
        else { try WallpaperEngine.validatePhoto(url) }
        try Task.checkCancellation()
        guard let display = connected().first(where: { $0.id == id }) else {
            throw NSError(domain: "WallpaperDisplay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "这块屏幕已断开，请连接后重新选择。"])
        }
        guard featureEnabled, !terminated, configurations[id] == previous else { throw CancellationError() }
        var next = configurations
        next[id] = DisplayConfiguration(name: display.name, path: url.path, kind: kind, stopped: false,
                                        playlist: playlist, interval: interval, playlistIndex: index, rotationEnabled: rotationEnabled,
                                        quality: UserDefaults.standard.string(forKey: "wallpaperQuality").flatMap(VideoQuality.init(rawValue:)) ?? configurations[id]?.quality,
                                        loopMode: UserDefaults.standard.string(forKey: "wallpaperLoop").flatMap(VideoLoopMode.init(rawValue:)) ?? configurations[id]?.loopMode)
        if kind == .photo {
            let workspace = NSWorkspace.shared
            let original = workspace.desktopImageURL(for: display.screen)
            let options = workspace.desktopImageOptions(for: display.screen)
            try WallpaperEngine(screens: [display.screen]).setPhoto(url)
            do { try store.save(next) }
            catch {
                if let original { try? workspace.setDesktopImageURL(original, for: display.screen, options: options ?? [:]) }
                throw error
            }
        } else { try store.save(next) }
        configurations = next
        errors.removeValue(forKey: id)
        displays = connected()
        deadlines[id] = nil
        await rebuildPlayback()
    }

    func setStopped(_ stopped: Bool, for id: String? = nil) async throws {
        var next = configurations
        for key in next.keys where (id == nil || key == id) && (next[key]?.kind == .video || next[key]?.playlist != nil) {
            next[key]?.stopped = stopped
        }
        try store.save(next)
        configurations = next
        if !stopped {
            for (key, config) in next where (id == nil || key == id) && config.kind == .video && errors[key] != nil {
                groups.removeValue(forKey: Self.videoKey(config))?.clear()
            }
        }
        if let id { errors.removeValue(forKey: id) }
        await rebuildPlayback()
    }

    func removeConfiguration(for id: String) async throws {
        var next = configurations
        next.removeValue(forKey: id)
        try store.save(next)
        configurations = next
        errors.removeValue(forKey: id)
        await rebuildPlayback()
    }

    func isPlaying(_ id: String) -> Bool {
        guard let config = configurations[id], config.kind == .video, !config.stopped else { return false }
        return groups[Self.videoKey(config)]?.isPlaying == true && displays.contains(where: { $0.id == id })
    }

    func setFeatureEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else { return }
        featureEnabled = enabled
        if !enabled {
            rotationTimer?.invalidate(); rotationTimer = nil
            deadlines.removeAll(); revision += 1
            for engine in groups.values { engine.clear() }
            groups.removeAll(); preparing.removeAll(); displays.removeAll()
        }
        onChange?()
    }

    func shutdown() {
        terminated = true
        rotationTimer?.invalidate()
        deadlines.removeAll()
        revision += 1
        for engine in groups.values { engine.clear() }
        groups.removeAll()
    }

    static func identify(_ url: URL) async throws -> DisplayConfiguration.Kind {
        // Validate actual contents, including files with missing or misleading extensions.
        if (try? WallpaperEngine.validatePhoto(url)) != nil { return .photo }
        try await WallpaperEngine.validateVideo(url)
        return .video
    }

    func selectFiles(_ urls: [URL], for id: String) async throws {
        let previous = configurations[id]
        var items: [WallpaperItem] = []
        for url in urls {
            try Task.checkCancellation()
            let item = WallpaperItem(path: url.path, kind: try await Self.identify(url))
            if !items.contains(item) { items.append(item) }
        }
        guard let first = items.first else { return }
        guard configurations[id] == previous else { throw CancellationError() }
        try await select(URL(fileURLWithPath: first.path), kind: first.kind, for: id,
                         playlist: items, interval: previous?.effectiveInterval ?? 300)
    }

    func setRotation(for id: String, interval: TimeInterval? = nil, enabled: Bool? = nil) throws {
        guard var config = configurations[id] else { return }
        if let interval {
            guard interval.isFinite, interval >= 10, interval <= 86400 else {
                throw NSError(domain: "Rotation", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入 10 到 86400 秒之间的间隔。"])
            }
            config.interval = interval
        }
        if let enabled { config.rotationEnabled = enabled }
        var next = configurations
        next[id] = config
        try store.save(next)
        configurations = next
        deadlines[id] = nil
        scheduleRotation()
        onChange?()
    }

    func advance(for id: String) async throws {
        guard let config = configurations[id], let items = config.playlist, items.count > 1 else { return }
        let current = items.indices.contains(config.playlistIndex ?? -1) ? config.playlistIndex! : 0
        var lastError: Error?
        for offset in 1..<items.count {
            let index = (current + offset) % items.count
            let item = items[index]
            do {
                try await select(URL(fileURLWithPath: item.path), kind: item.kind, for: id,
                                 playlist: items, interval: config.effectiveInterval, index: index,
                                 rotationEnabled: config.rotationEnabled != false)
                return
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
            guard configurations[id] == config else { throw CancellationError() }
        }
        if let lastError { throw lastError }
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard featureEnabled, !terminated, policy.shouldPlay else { deadlines.removeAll(); return }
        let eligible = Set(displays.compactMap { configurations[$0.id]?.isRotating == true ? $0.id : nil })
        deadlines = deadlines.filter { eligible.contains($0.key) }
        for id in eligible where deadlines[id] == nil {
            deadlines[id] = Date().addingTimeInterval(configurations[id]!.effectiveInterval)
        }
        guard !rotating, let next = deadlines.values.min() else { return }
        let timer = Timer(timeInterval: max(0.1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.rotateDue() }
        }
        timer.tolerance = 0.5
        rotationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func rotateDue() async {
        guard featureEnabled, !rotating, !terminated, policy.shouldPlay else { scheduleRotation(); return }
        rotating = true
        let due = deadlines.filter { $0.value <= Date() }.map(\.key)
        for id in due {
            guard featureEnabled, !terminated, policy.shouldPlay, configurations[id]?.isRotating == true,
                  connected().contains(where: { $0.id == id }) else { continue }
            do { try await advance(for: id) }
            catch is CancellationError {}
            catch { errors[id] = error.localizedDescription }
            deadlines[id] = Date().addingTimeInterval(configurations[id]?.effectiveInterval ?? 300)
        }
        rotating = false
        scheduleRotation()
        onChange?()
    }

    private static func videoKey(_ config: DisplayConfiguration) -> String {
        config.url.standardizedFileURL.resolvingSymlinksInPath().path
            + "|" + config.effectiveQuality.rawValue + "|" + config.effectiveLoopMode.rawValue
    }

    func setGlobalOptions(quality: VideoQuality? = nil, loopMode: VideoLoopMode? = nil) async throws {
        var next = configurations
        for id in Array(next.keys) {
            if let quality { next[id]?.quality = quality }
            if let loopMode { next[id]?.loopMode = loopMode }
        }
        try store.save(next)
        configurations = next
        if let quality { UserDefaults.standard.set(quality.rawValue, forKey: "wallpaperQuality") }
        if let loopMode { UserDefaults.standard.set(loopMode.rawValue, forKey: "wallpaperLoop") }
        await rebuildPlayback()
    }

    func setOptions(for id: String, quality: VideoQuality? = nil, loopMode: VideoLoopMode? = nil) async throws {
        guard var config = configurations[id], config.kind == .video else { return }
        if let quality { config.quality = quality }
        if let loopMode { config.loopMode = loopMode }
        var next = configurations
        next[id] = config
        try store.save(next)
        configurations = next
        errors.removeValue(forKey: id)
        await rebuildPlayback()
    }

    func isDesktopHidden(_ id: String) -> Bool {
        guard let config = configurations[id] else { return false }
        return groups[Self.videoKey(config)]?.desktopHidden == true
    }

    func setAutomaticPause(_ enabled: Bool) {
        automaticallyPauseWhenOccluded = enabled
        for engine in groups.values { engine.setAutomaticPause(enabled) }
        onChange?()
    }

    private func rebuildPlayback() async {
        guard featureEnabled, !terminated else { return }
        revision += 1
        let current = revision
        preparing.removeAll()
        var desired: [String: [DisplayTarget]] = [:]
        for display in displays {
            guard let config = configurations[display.id], config.kind == .video, !config.stopped else { continue }
            desired[Self.videoKey(config), default: []].append(display)
        }
        for key in Array(groups.keys) where desired[key] == nil {
            groups.removeValue(forKey: key)?.clear()
        }
        // Reconfigure existing groups before any suspension point.
        for (key, targets) in desired {
            groups[key]?.setScreens(targets.map(\.screen))
        }
        onChange?()
        for (key, targets) in desired where groups[key] == nil {
            do {
                guard let config = configurations[targets[0].id] else { continue }
                let source = config.url
                try await WallpaperEngine.validateVideo(source)
                guard current == revision else { return }
                preparing.formUnion(targets.map(\.id))
                onChange?()
                let url = try await cache.prepare(source, quality: config.effectiveQuality)
                try Task.checkCancellation()
                guard current == revision else { return }
                let engine = WallpaperEngine(screens: targets.map(\.screen), loopMode: config.effectiveLoopMode,
                    automaticallyPauseWhenOccluded: automaticallyPauseWhenOccluded)
                engine.onVisibilityChange = { [weak self] in self?.onChange?() }
                engine.policy = policy
                engine.onFailure = { [weak self] error in
                    guard let self else { return }
                    for display in self.displays {
                        guard let config = self.configurations[display.id], config.kind == .video,
                              Self.videoKey(config) == key else { continue }
                        self.errors[display.id] = error.localizedDescription
                    }
                    self.onChange?()
                }
                engine.useValidatedVideo(url)
                groups[key] = engine
                for display in targets { errors.removeValue(forKey: display.id); preparing.remove(display.id) }
            } catch {
                guard current == revision else { return }
                // Leave the saved record intact. One missing file must not block other screens.
                for display in targets { errors[display.id] = error.localizedDescription; preparing.remove(display.id) }
            }
        }
        if current == revision { scheduleRotation(); onChange?() }
    }
}
