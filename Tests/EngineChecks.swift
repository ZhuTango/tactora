import AppKit
import AVFoundation

@MainActor
final class EngineChecks {
    func testInvalidVideoDoesNotReplaceCurrentVideo() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = WallpaperEngine(automaticallyPauseWhenOccluded: false)
        defer { engine.clear() }
        try await engine.loadVideo(url)
        let originalPlayer = engine.player
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("not a movie".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do {
            try await engine.loadVideo(invalid)
            fail("Corrupt media must be rejected")
        } catch {}
        checkEqual(engine.videoURL, url)
        check(engine.player === originalPlayer)
    }

    func testPlaybackLoopsAndStopReleasesPlayerAndDesktopWindows() async throws {
        _ = NSApplication.shared
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = WallpaperEngine(automaticallyPauseWhenOccluded: false)
        defer { engine.clear() }
        try await engine.loadVideo(url)
        check(engine.player?.isMuted == true)
        checkEqual(engine.windows.count, NSScreen.screens.count)
        check(engine.windows.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey })
        // The fixture is 0.5 seconds; observe playback beyond several complete loops.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        check((engine.looper?.loopCount ?? 0) > 0, "Video must loop")
        for window in engine.windows {
            let layer = try unwrap((window.contentView as? VideoView)?.playerLayer)
            check(layer.isReadyForDisplay, "Every screen must have a decoded video frame")
            check(layer.videoRect.width > 0, "Video must have visible geometry")
        }
        reportMemory("playing")
        let previousPlayer = WeakReference(engine.player)
        engine.policy.userStopped = true
        checkNil(engine.player)
        check(engine.windows.isEmpty)
        checkEqual(engine.videoURL, url)
        // Give AVFoundation the next run-loop turns to finish pending work.
        try await Task.sleep(nanoseconds: 200_000_000)
        checkNil(previousPlayer.value)
        reportMemory("stopped")
        engine.policy.userStopped = false
        checkNotNil(engine.player)
        engine.policy.displayAsleep = true
        checkNil(engine.player)
        engine.policy.lowPowerMode = true
        engine.policy.displayAsleep = false
        checkNil(engine.player)
        engine.policy.lowPowerMode = false
        checkNotNil(engine.player)
        engine.clear()
        checkNil(engine.videoURL)
        checkNil(engine.player)
    }

    func testCancelledLoadDoesNotStartPlayback() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = WallpaperEngine(automaticallyPauseWhenOccluded: false)
        defer { engine.clear() }
        let task = Task { try await engine.loadVideo(url) }
        task.cancel()
        do {
            try await task.value
            fail("Cancelled selection must not start playing")
        } catch {}
        checkNil(engine.player)
        checkNil(engine.videoURL)
    }

    func testCorruptPhotoIsRejected() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not a photo".utf8).write(to: url)
        do { try WallpaperEngine.validatePhoto(url); fail("Corrupt photo accepted") } catch {}
    }

    func testPhotoSetsSystemWallpaperAndRestoresOriginal() async throws {
        let workspace = NSWorkspace.shared
        let originals = NSScreen.screens.map { ($0, workspace.desktopImageURL(for: $0), workspace.desktopImageOptions(for: $0)) }
        guard !originals.isEmpty, originals.allSatisfy({ $0.1 != nil }) else {
            throw NSError(domain: "Checks", code: 2, userInfo: [NSLocalizedDescriptionKey: "No restorable system wallpaper"])
        }
        // Keep a recovery record before any global desktop change.
        let backup = originals.map { ["screen": String(describing: $0.0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]!), "url": $0.1!.absoluteString] }
        try JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted).write(to: URL(fileURLWithPath: ".build/wallpaper-backup.json"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
        let color = NSColor(deviceRed: 0.1, green: 0.5, blue: 0.6, alpha: 1)
        for x in 0..<64 { for y in 0..<64 { bitmap.setColor(color, atX: x, y: y) } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let targets = DisplayTarget.connected()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DisplayConfigurationStore(url: directory.appendingPathComponent("displays.json"))
        let video = try await makeVideo()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: video)
        }
        let controller = try WallpaperController(store: store, automaticallyPauseWhenOccluded: false)
        var restoredController: WallpaperController?
        var operationError: Error?
        var applied = false
        var independentAndSaved = false
        do {
            await controller.refreshDisplays()
            if targets.count > 1 { try await controller.select(video, kind: .video, for: targets[1].id) }
            try await controller.select(url, kind: .photo, for: targets[0].id)
            for _ in 0..<40 {
                applied = originals.allSatisfy { snapshot in
                    let expected = snapshot.0 === targets[0].screen ? url : snapshot.1!
                    return workspace.desktopImageURL(for: snapshot.0)?.standardizedFileURL == expected.standardizedFileURL
                }
                if applied { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            independentAndSaved = controller.configurations[targets[0].id]?.kind == .photo
                && (targets.count < 2 || controller.isPlaying(targets[1].id))
            controller.shutdown()
            restoredController = try WallpaperController(store: store, automaticallyPauseWhenOccluded: false)
            await restoredController!.refreshDisplays()
            independentAndSaved = independentAndSaved
                && restoredController!.configurations[targets[0].id]?.url == url
                && (targets.count < 2 || restoredController!.isPlaying(targets[1].id))
        } catch { operationError = error }
        controller.shutdown()
        restoredController?.shutdown()
        // Restore before asserting; assertion traps must never bypass restoration.
        for (screen, original, options) in originals {
            try workspace.setDesktopImageURL(original!, for: screen, options: options ?? [:])
        }
        var restored = false
        for _ in 0..<40 {
            restored = originals.allSatisfy { workspace.desktopImageURL(for: $0.0)?.standardizedFileURL == $0.1?.standardizedFileURL }
            if restored { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        check(restored, "Original wallpaper must be restored; recovery record: .build/wallpaper-backup.json")
        try? FileManager.default.removeItem(at: url)
        if let operationError { throw operationError }
        check(applied, "System wallpaper did not update within 4 seconds")
        check(independentAndSaved, "Mixed photo/video configurations must persist and restore independently")
    }

    func testIndependentDisplaysAndReconnect() async throws -> Bool {
        _ = NSApplication.shared
        let screens = NSScreen.screens
        guard screens.count >= 2 else {
            print("SKIP: independent physical display check requires two screens")
            return false
        }
        let first = DisplayTarget(id: "test-display-A", name: "Screen A", screen: screens[0])
        let second = DisplayTarget(id: "test-display-B", name: "Screen B", screen: screens[1])
        var attached = [first, second]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DisplayConfigurationStore(url: directory.appendingPathComponent("displays.json"))
        let videoA = try await makeVideo()
        let videoB = try await makeVideo()
        defer {
            try? FileManager.default.removeItem(at: videoA)
            try? FileManager.default.removeItem(at: videoB)
            try? FileManager.default.removeItem(at: directory)
        }
        let controller = try WallpaperController(store: store, automaticallyPauseWhenOccluded: false, connected: { attached })
        defer { controller.shutdown() }
        await controller.refreshDisplays()
        try await controller.select(videoA, kind: .video, for: first.id)
        checkEqual(controller.groups.count, 1)
        checkEqual(controller.groups.values.first?.windows.count, 1)
        checkNil(controller.configurations[second.id])
        try await controller.select(videoA, kind: .video, for: second.id)
        checkEqual(controller.groups.count, 1)
        checkEqual(controller.groups.values.first?.windows.count, 2)
        let sharedPlayer = controller.groups.values.first?.player
        try await controller.setStopped(true, for: first.id)
        checkEqual(controller.groups.count, 1)
        checkEqual(controller.groups.values.first?.windows.count, 1)
        check(controller.groups.values.first?.player === sharedPlayer)
        check(controller.isPlaying(second.id))
        try await controller.setStopped(false, for: first.id)
        checkEqual(controller.groups.count, 1)
        checkEqual(controller.groups.values.first?.windows.count, 2)
        try await controller.select(videoB, kind: .video, for: second.id)
        checkEqual(controller.groups.count, 2)
        let beforeInvalidSelection = controller.configurations
        do {
            try await controller.select(URL(fileURLWithPath: "/missing/selection.mov"), kind: .video, for: first.id)
            fail("A missing file must not overwrite saved per-screen choices")
        } catch {}
        checkEqual(controller.configurations, beforeInvalidSelection)
        checkEqual(try store.load(), beforeInvalidSelection)
        let a = try unwrap(controller.groups.values.first(where: { $0.videoURL?.lastPathComponent == videoA.lastPathComponent }))
        let b = try unwrap(controller.groups.values.first(where: { $0.videoURL?.lastPathComponent == videoB.lastPathComponent }))
        checkEqual(a.windows.first?.frame, screens[0].frame)
        checkEqual(b.windows.first?.frame, screens[1].frame)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        for engine in [a, b] {
            let layer = try unwrap((engine.windows.first?.contentView as? VideoView)?.playerLayer)
            check(layer.isReadyForDisplay, "Each independent video must decode")
        }
        try await controller.setStopped(true, for: first.id)
        check(!controller.isPlaying(first.id))
        check(controller.isPlaying(second.id))
        checkNil(a.player)
        checkEqual(try store.load()[first.id]?.stopped, true)
        controller.shutdown()
        let restored = try WallpaperController(store: store, automaticallyPauseWhenOccluded: false, connected: { attached })
        defer { restored.shutdown() }
        await restored.refreshDisplays()
        checkEqual(restored.configurations[first.id]?.url, videoA)
        checkEqual(restored.configurations[second.id]?.url, videoB)
        check(!restored.isPlaying(first.id))
        check(restored.isPlaying(second.id))
        attached = [first]
        await restored.refreshDisplays()
        checkEqual(restored.groups.count, 0)
        checkNotNil(restored.configurations[second.id])
        // Reordering the displays must not swap their saved backgrounds.
        attached = [second, first]
        await restored.refreshDisplays()
        check(restored.isPlaying(second.id))
        check(!restored.isPlaying(first.id))
        try await restored.setStopped(false, for: first.id)
        check(restored.isPlaying(first.id))
        restored.policy.lowPowerMode = true
        check(restored.groups.values.allSatisfy { $0.player == nil })
        restored.policy.lowPowerMode = false
        check(restored.isPlaying(first.id) && restored.isPlaying(second.id))
        try await restored.removeConfiguration(for: second.id)
        checkNil(try store.load()[second.id])
        check(restored.isPlaying(first.id))
        // A missing file must not prevent the healthy display from restoring.
        restored.shutdown()
        var records = try store.load()
        records[second.id] = DisplayConfiguration(name: "Missing", path: "/missing/video.mov", kind: .video, stopped: false)
        try store.save(records)
        let partial = try WallpaperController(store: store, automaticallyPauseWhenOccluded: false, connected: { attached })
        defer { partial.shutdown() }
        await partial.refreshDisplays()
        check(partial.isPlaying(first.id))
        checkNotNil(partial.errors[second.id])
        checkEqual(try store.load()[second.id]?.path, "/missing/video.mov")
        return true
    }

    func makeVideo(fps: Int32 = 30, frameCount: Int = 15) async throws -> URL {
        let width = Int(ProcessInfo.processInfo.environment["TEST_VIDEO_WIDTH"] ?? "320") ?? 320
        let height = width * 9 / 16
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: width,
                                         kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        check(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = try unwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 12), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            check(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        checkEqual(writer.status, .completed)
        return url
    }
}

private final class WeakReference<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}
