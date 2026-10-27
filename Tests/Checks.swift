import Foundation

@main
struct Checks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--wallpaper-preferences-only") {
            try await checkGlobalWallpaperPreferences(); return
        }
        try checkClipboard()
        if CommandLine.arguments.contains("--clipboard-only") { return }
        for key in [\PlaybackPolicy.userStopped, \.displayAsleep, \.systemAsleep, \.sessionInactive, \.lowPowerMode] {
            var policy = PlaybackPolicy()
            precondition(policy.shouldPlay)
            policy[keyPath: key] = true
            precondition(!policy.shouldPlay, "Playback must stop to release resources")
        }
        var policy = PlaybackPolicy()
        policy.userStopped = true
        policy.displayAsleep = true
        policy.displayAsleep = false
        precondition(!policy.shouldPlay, "Wake must not override user stop")
        print("PASS: resource-saving conditions and wake policy")
        checkCoverageGeometry()
        try await checkCacheConversion()
        print("PASS: cache conversion to 30 fps, reuse, deduplication, corruption repair, invalidation and cancellation")
        try checkOptimizationDefaults()
        print("PASS: backward-compatible low-resource defaults")
        try checkDisplayPersistence()
        print("PASS: independent configuration persistence and corrupt-file protection")
        try checkLegacyMigration()
        print("PASS: stable display identities and one-time legacy configuration migration")
        let engine = EngineChecks()
        let fixture = try await engine.makeVideo()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await checkPlaylist()
        print("PASS: mixed playlist detection, timer, persistence, stop, sleep, reconnect and invalid files")
        try await checkPosterContinuity()
        print("PASS: frozen frame during decoder release, ready-only display and resume position")
        try await checkOptimizedPlayback(fixture)
        print("PASS: single-item looping, occlusion pause, delayed release and resume")
        if ProcessInfo.processInfo.environment["TEST_NATIVE_OCCLUSION"] == "1" {
            try await checkNativeOcclusion(fixture)
            print("PASS: actual AppKit window occlusion suspends playback")
        }
        try await engine.testInvalidVideoDoesNotReplaceCurrentVideo()
        print("PASS: invalid video preserves active wallpaper")
        try await engine.testPlaybackLoopsAndStopReleasesPlayerAndDesktopWindows()
        print("PASS: looping, mute, desktop windows, stop, resume and sleep cleanup")
        try await engine.testCancelledLoadDoesNotStartPlayback()
        print("PASS: cancelled selection does not start playback")
        engine.testCorruptPhotoIsRejected()
        print("PASS: corrupt photo rejected")
        if try await engine.testIndependentDisplaysAndReconnect() {
            print("PASS: independent videos, sharing, stop persistence, restart, reconnect, reorder and missing-file isolation")
        }
        try await engine.testPhotoSetsSystemWallpaperAndRestoresOriginal()
        print("PASS: mixed photo/video per-display settings, restart restore; original wallpaper restored")
    }
}

func check(_ value: @autoclosure () -> Bool, _ message: String = "Check failed", file: StaticString = #filePath, line: UInt = #line) {
    precondition(value(), message, file: (file), line: line)
}
func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    check(a == b, "Expected \(b), got \(a)", file: file, line: line)
}
func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    check(value == nil, "Expected nil", file: file, line: line)
}
func checkNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    check(value != nil, "Expected non-nil", file: file, line: line)
}
func fail(_ message: String) { preconditionFailure(message) }
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Checks", code: 1) }
    return value
}

@MainActor
func checkGlobalWallpaperPreferences() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let keys = ["wallpaperQuality", "wallpaperLoop"]
    let old = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer { for (key, value) in zip(keys, old) { UserDefaults.standard.set(value, forKey: key) } }
    let store = DisplayConfigurationStore(url: folder.appendingPathComponent("displays.json"))
    let records = ["home": DisplayConfiguration(name: "Home", path: "/home.mp4", kind: .video, stopped: true),
                   "office": DisplayConfiguration(name: "Office", path: "/office.jpg", kind: .photo, stopped: false)]
    try store.save(records)
    let controller = try WallpaperController(store: store, connected: { [] })
    try await controller.setGlobalOptions(quality: .balanced, loopMode: .seamless)
    let saved = try store.load()
    precondition(saved.count == 2)
    for (id, record) in records {
        precondition(saved[id]?.path == record.path && saved[id]?.stopped == record.stopped)
        precondition(saved[id]?.quality == .balanced && saved[id]?.loopMode == .seamless)
    }
    precondition(UserDefaults.standard.string(forKey: "wallpaperQuality") == "balanced")
    precondition(UserDefaults.standard.string(forKey: "wallpaperLoop") == "seamless")
    print("PASS: global preferences persist for video/photo/offline records without losing files or playback state")
}
