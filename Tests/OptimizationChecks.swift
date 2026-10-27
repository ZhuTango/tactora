import AppKit
import AVFoundation

@MainActor
func checkOptimizationDefaults() throws {
    let old = Data("{\"name\":\"screen\",\"path\":\"/tmp/file.mov\",\"kind\":\"video\",\"stopped\":false}".utf8)
    let config = try JSONDecoder().decode(DisplayConfiguration.self, from: old)
    checkEqual(config.effectiveQuality, .original)
    checkEqual(config.effectiveLoopMode, .efficient)
}

@MainActor
func checkOptimizedPlayback(_ url: URL) async throws {
    let engine = WallpaperEngine(screens: Array(NSScreen.screens.prefix(1)), loopMode: .efficient,
        automaticallyPauseWhenOccluded: false, idleReleaseDelay: 0.2)
    defer { engine.clear() }
    try await engine.loadVideo(url)
    try await Task.sleep(nanoseconds: 1_800_000_000)
    checkNil(engine.looper)
    checkEqual(engine.player?.items().count, 1)
    check(engine.completedLoops >= 2, "Single-item loop must actually repeat")
    engine.setDesktopVisible(false)
    checkEqual(engine.player?.rate, 0)
    check(!engine.isPlaying)
    try await Task.sleep(nanoseconds: 400_000_000)
    checkNil(engine.player)
    check(!engine.windows.isEmpty, "Keep windows to receive future visibility changes")
    for window in engine.windows {
        check(!window.isOpaque, "A released decoder must not leave an opaque black desktop window")
        checkEqual(window.backgroundColor.alphaComponent, 0)
    }
    engine.setDesktopVisible(true)
    checkNotNil(engine.player)
    check(engine.isPlaying)
    engine.policy.userStopped = true
    engine.setDesktopVisible(true)
    checkNil(engine.player)
}

@MainActor
func checkNativeOcclusion(_ url: URL) async throws {
    guard let screen = NSScreen.screens.last else { return }
    let engine = WallpaperEngine(screens: [screen], loopMode: .efficient, idleReleaseDelay: 0.2)
    defer { engine.clear() }
    try await engine.loadVideo(url)
    let cover = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    cover.isReleasedWhenClosed = false
    cover.backgroundColor = .systemBlue
    cover.isOpaque = true
    cover.level = .floating
    cover.setFrame(screen.frame, display: true)
    cover.orderFront(nil)
    defer { cover.close() }
    try await Task.sleep(nanoseconds: 2_600_000_000)
    check(engine.desktopHidden, "Native occlusion notification must suspend a fully covered desktop")
    checkNil(engine.player)
}

func checkCoverageGeometry() {
    let target = CGRect(x: -100, y: 50, width: 100, height: 100)
    check(!DesktopCoverage.fullyCovered(target, by: []))
    check(DesktopCoverage.fullyCovered(target, by: [target]))
    check(DesktopCoverage.fullyCovered(target, by: [CGRect(x: -100, y: 50, width: 50, height: 100), CGRect(x: -50, y: 50, width: 50, height: 100)]))
    check(!DesktopCoverage.fullyCovered(target, by: [CGRect(x: -100, y: 50, width: 99, height: 100)]))
    check(!DesktopCoverage.fullyCovered(target, by: [CGRect(x: -100, y: 50, width: 60, height: 100), CGRect(x: -100, y: 50, width: 60, height: 100)]))
}

@MainActor
func checkCacheConversion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = VideoCache(directory: root)
    let source = try await EngineChecks().makeVideo(fps: 60)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
    }
    let original = try Data(contentsOf: source)
    async let a = cache.prepare(source, quality: .economy)
    async let b = cache.prepare(source, quality: .economy)
    let (first, shared) = try await (a, b)
    checkEqual(first, shared)
    check(first != source)
    let asset = AVURLAsset(url: first)
    let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
    let rate = try await track.load(.nominalFrameRate)
    check(rate <= 30.01)
    checkEqual(try await asset.loadTracks(withMediaType: .audio).count, 0)
    let modified = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let again = try await VideoCache(directory: root).prepare(source, quality: .economy)
    checkEqual(first, again)
    checkEqual(try again.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
    checkEqual(try Data(contentsOf: source), original)
    checkEqual(try await cache.prepare(source, quality: .original), source)
    try Data("corrupt cache".utf8).write(to: first)
    _ = try await cache.prepare(source, quality: .economy)
    let repaired = try await AVURLAsset(url: first).load(.isPlayable)
    check(repaired)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: source.path)
    let replaced = try await cache.prepare(source, quality: .economy)
    check(replaced != first, "Changed source must invalidate cache")
    let cancelled = Task { try await cache.prepare(source, quality: .balanced) }
    cancelled.cancel()
    do { _ = try await cancelled.value; fail("Cancelled prepare should not be applied") } catch is CancellationError {}
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    check(!names.contains { $0.contains("partial") })
}

@MainActor
func checkPosterContinuity() async throws {
    let source = try await EngineChecks().makeVideo(frameCount: 120)
    defer { try? FileManager.default.removeItem(at: source) }
    let engine = WallpaperEngine(screens: Array(NSScreen.screens.prefix(1)), loopMode: .efficient,
        automaticallyPauseWhenOccluded: false, idleReleaseDelay: 0.2)
    defer { engine.clear() }
    try await engine.loadVideo(source)
    let view = try unwrap(engine.windows.first?.contentView as? VideoView)
    try await Task.sleep(nanoseconds: 1_200_000_000)
    engine.setDesktopVisible(false)
    let paused = try unwrap(engine.player).currentTime().seconds
    check(paused > 0.5)
    try await Task.sleep(nanoseconds: 500_000_000)
    checkNil(engine.player)
    let contents = try unwrap(view.posterLayer.contents)
    checkEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
    let image = contents as! CGImage
    check(image.width <= 1280 && image.height <= 1280)
    check(view.playerLayer.isHidden, "A decoder-free player layer must not cover the frozen frame")
    checkEqual(view.posterLayer.frame, view.bounds)
    engine.setDesktopVisible(true)
    check(view.playerLayer.isHidden, "Keep the poster visible while the replacement player seeks")
    checkNotNil(view.posterLayer.contents)
    for _ in 0..<30 {
        if view.playerLayer.isReadyForDisplay && !view.playerLayer.isHidden { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    check(view.playerLayer.isReadyForDisplay && !view.playerLayer.isHidden)
    check((engine.player?.currentTime().seconds ?? 0) >= paused - 0.1,
          "Cold resume must seek back to the paused position rather than frame zero")
    engine.refreshDisplays()
    let refreshed = try unwrap(engine.windows.first?.contentView as? VideoView)
    for _ in 0..<30 {
        if !refreshed.playerLayer.isHidden { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    check(!refreshed.playerLayer.isHidden, "Display rebuild must not leave the video masked")
    engine.clear()
    checkNil(view.playerLayer.player)
}
