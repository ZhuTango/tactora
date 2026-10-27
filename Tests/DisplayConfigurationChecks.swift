import AppKit

@MainActor
func checkDisplayPersistence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DisplayConfigurationStore(url: directory.appendingPathComponent("displays.json"))
    let records = [
        "display-A": DisplayConfiguration(name: "主屏", path: "/tmp/a.mov", kind: .video, stopped: true),
        "display-B": DisplayConfiguration(name: "副屏", path: "/tmp/b.png", kind: .photo, stopped: false)
    ]
    try store.save(records)
    checkEqual(try DisplayConfigurationStore(url: store.url).load(), records)
    var updated = records
    updated["display-B"]?.path = "/tmp/c.png"
    try store.save(updated)
    checkEqual(try store.load()["display-A"], records["display-A"])
    try Data("broken JSON".utf8).write(to: store.url)
    do { _ = try store.load(); fail("Corrupt configuration must not silently reset") } catch {}
    checkEqual(try String(contentsOf: store.url), "broken JSON")
}

@MainActor
func checkLegacyMigration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "WallpaperChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = DisplayConfigurationStore(url: directory.appendingPathComponent("displays.json"))
    let targets = DisplayTarget.connected()
    check(!targets.isEmpty)
    checkEqual(Set(targets.map(\.id)).count, targets.count)
    defaults.set("/tmp/legacy.mov", forKey: "videoPath")
    defaults.set(true, forKey: "videoStopped")
    let controller = try WallpaperController(store: store)
    try controller.migrateLegacy(defaults: defaults)
    checkEqual(controller.configurations.count, targets.count)
    check(controller.configurations.values.allSatisfy { $0.path == "/tmp/legacy.mov" && $0.stopped })
    checkNil(defaults.string(forKey: "videoPath"))
    let saved = try store.load()
    defaults.set("/tmp/another.mov", forKey: "videoPath")
    try controller.migrateLegacy(defaults: defaults)
    checkEqual(try store.load(), saved)
}
