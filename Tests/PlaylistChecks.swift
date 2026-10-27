import AppKit

@MainActor
func checkPlaylist() async throws {
    let target = try unwrap(DisplayTarget.connected().first)
    let workspace = NSWorkspace.shared
    let original = try unwrap(workspace.desktopImageURL(for: target.screen))
    let options = workspace.desktopImageOptions(for: target.screen) ?? [:]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let photo = root.appendingPathComponent("photo.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32)!
    for x in 0..<16 { for y in 0..<16 { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.5, blue: 0.6, alpha: 1), atX: x, y: y) } }
    try bitmap.representation(using: .png, properties: [:])!.write(to: photo)
    let video = try await EngineChecks().makeVideo()
    let store = DisplayConfigurationStore(url: root.appendingPathComponent("config.json"))
    var attached = [target]
    let controller = try WallpaperController(store: store, automaticallyPauseWhenOccluded: false, connected: { attached })
    defer {
        controller.shutdown()
        try? workspace.setDesktopImageURL(original, for: target.screen, options: options)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: video)
    }
    await controller.refreshDisplays()
    checkEqual(try await WallpaperController.identify(photo), .photo)
    checkEqual(try await WallpaperController.identify(video), .video)
    try await controller.selectFiles([photo, video, photo], for: target.id)
    checkEqual(controller.configurations[target.id]?.playlist?.count, 2)
    checkEqual(controller.configurations[target.id]?.kind, .photo)
    try controller.setRotation(for: target.id, interval: 10)
    try await Task.sleep(nanoseconds: 11_500_000_000)
    checkEqual(controller.configurations[target.id]?.kind, .video)
    check(controller.isPlaying(target.id), "Real timer must advance photo to video")
    try await controller.advance(for: target.id)
    checkEqual(controller.configurations[target.id]?.kind, .photo)
    check(controller.groups.isEmpty, "Photo must release video playback")
    let saved = try store.load()
    checkEqual(saved, controller.configurations)
    let restored = try WallpaperController(store: store, connected: { attached })
    checkEqual(restored.configurations, saved)
    restored.shutdown()
    try await controller.setStopped(true, for: target.id)
    check(controller.configurations[target.id]?.isRotating == false)
    try await Task.sleep(nanoseconds: 10_700_000_000)
    checkEqual(controller.configurations[target.id]?.kind, .photo)
    try await controller.setStopped(false, for: target.id)
    controller.policy.displayAsleep = true
    try await Task.sleep(nanoseconds: 10_700_000_000)
    checkEqual(controller.configurations[target.id]?.kind, .photo)
    controller.policy.displayAsleep = false
    attached = []
    await controller.refreshDisplays()
    check(controller.groups.isEmpty)
    attached = [target]
    await controller.refreshDisplays()
    let before = controller.configurations
    do {
        try await controller.selectFiles([photo, root.appendingPathComponent("missing.mov")], for: target.id)
        fail("Invalid selection must fail atomically")
    } catch {}
    checkEqual(controller.configurations, before)
    do { try controller.setRotation(for: target.id, interval: .nan); fail("Invalid interval") } catch {}
    try await controller.advance(for: target.id)
    let disposable = root.appendingPathComponent("removed.png")
    try FileManager.default.copyItem(at: photo, to: disposable)
    try await controller.selectFiles([video, disposable, photo], for: target.id)
    try FileManager.default.removeItem(at: disposable)
    try await controller.advance(for: target.id)
    checkEqual(controller.configurations[target.id]?.path, photo.path)
    try await controller.advance(for: target.id)
    try FileManager.default.removeItem(at: photo)
    do { try await controller.advance(for: target.id); fail("Missing alternative must report failure") } catch {}
    checkEqual(controller.configurations[target.id]?.kind, .video)
    try await controller.select(video, kind: .video, for: target.id)
    checkNil(controller.configurations[target.id]?.playlist)
    try await controller.removeConfiguration(for: target.id)
    checkNil(try store.load()[target.id])
}
