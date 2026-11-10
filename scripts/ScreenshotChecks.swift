import AppKit
@main struct ScreenshotChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let source = NSImage(size: NSSize(width: 640, height: 360))
        source.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        source.unlockFocus()
        let canvas = ScreenshotCanvas(image: source)
        let size = canvas.image.size
        let area = ScreenshotAnnotation(tool: .cover, start: NSPoint(x: 40, y: 40), end: NSPoint(x: 150, y: 150))
        canvas.append(area)
        guard let png = canvas.pngData(), let bitmap = NSBitmapImageRep(data: png) else { fatalError("PNG export") }
        precondition(bitmap.pixelsWide == Int(size.width) && bitmap.pixelsHigh == Int(size.height), "Keep Retina pixel dimensions")
        let candidates = [bitmap.colorAt(x: 80, y: 80), bitmap.colorAt(x: 80, y: bitmap.pixelsHigh - 80)]
        precondition(candidates.compactMap { $0?.usingColorSpace(.deviceRGB) }.contains { $0.redComponent < 0.01 && $0.alphaComponent == 1 }, "Redaction exports opaque black pixels")
        canvas.selectionEnabled = true
        canvas.selection = NSRect(x: 40, y: 40, width: 110, height: 110)
        let cropped = NSBitmapImageRep(data: canvas.pngData()!)!
        precondition(cropped.pixelsWide == 110 && cropped.pixelsHigh == 110)
        let pixel = cropped.colorAt(x: 50, y: 50)!.usingColorSpace(.deviceRGB)!
        precondition(pixel.redComponent < 0.01 && pixel.alphaComponent == 1, "Crop excludes selection UI and keeps opaque annotations")
        canvas.selection = nil
        precondition(canvas.pngData() == nil, "Unselected display must not export accidentally")
        canvas.selectionEnabled = false
        let limits = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let selected = NSRect(x: 100, y: 100, width: 300, height: 200)
        for (index, point) in ScreenshotSelection.handles(selected).enumerated() {
            precondition(ScreenshotSelection.hitHandle(point, rect: selected, tolerance: 8) == index)
            let resized = ScreenshotSelection.drag(handle: index, start: point, point: NSPoint(x: point.x + 20, y: point.y + 20), original: selected, bounds: limits)
            precondition(resized != selected && limits.contains(resized))
        }
        let moved = ScreenshotSelection.drag(handle: -2, start: .zero, point: NSPoint(x: 2000, y: 2000), original: selected, bounds: limits)
        precondition(moved.maxX == limits.maxX && moved.maxY == limits.maxY && moved.size == selected.size)
        let reversed = ScreenshotSelection.drag(handle: -1, start: NSPoint(x: 500, y: 400), point: NSPoint(x: 100, y: 100), original: .zero, bounds: limits)
        precondition(reversed == NSRect(x: 100, y: 100, width: 400, height: 300))
        print("PASS: eight resize handles, reverse selection, clamped movement and pixel-accurate cropped export")
        canvas.undoAnnotation(); precondition(canvas.annotations.isEmpty && canvas.canRedo)
        canvas.redoAnnotation(); precondition(canvas.annotations.count == 1)
        canvas.undoAnnotation()
        canvas.append(ScreenshotAnnotation(tool: .arrow, start: NSPoint(x: 30, y: 30), end: NSPoint(x: 200, y: 150)))
        precondition(!canvas.canRedo, "New annotation invalidates redo")
        let preview = ScreenshotWindow(image: source)
        precondition(preview.window?.hidesOnDeactivate == false, "Screenshot preview must stay visible when the captured app is active")
        precondition(preview.window?.collectionBehavior.contains(.canJoinAllSpaces) == true, "Screenshot preview must be reachable on the capture Space")
        precondition(preview.canvas.editing, "Capture opens directly into annotation")
        preview.canvas.beginText(at: NSPoint(x: 80, y: 100))
        let textField = preview.canvas.subviews.compactMap { $0 as? NSTextField }.first!
        textField.stringValue = "Inline text"
        preview.canvas.commitText()
        precondition(preview.canvas.annotations.last?.text == "Inline text")
        precondition(preview.canvas.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        preview.canvas.append(area)
        preview.canvas.append(ScreenshotAnnotation(tool: .rectangle, start: NSPoint(x: 180, y: 70), end: NSPoint(x: 400, y: 220)))
        preview.canvas.append(ScreenshotAnnotation(tool: .arrow, start: NSPoint(x: 450, y: 280), end: NSPoint(x: 320, y: 180)))
        preview.canvas.append(ScreenshotAnnotation(tool: .text, start: NSPoint(x: 180, y: 250), end: .zero, text: "Tactora 截图"))
        preview.editImage()
        if CommandLine.arguments.contains("--overlay"), let screen = NSScreen.main {
            preview.close()
            let overlay = ScreenshotWindow(image: source, captureScreen: screen)
            overlay.canvas.selection = NSRect(x: 150, y: 120, width: 900, height: 400)
            NSApp.setActivationPolicy(.regular)
            overlay.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }
        if CommandLine.arguments.contains("--interactive") {
            NSApp.setActivationPolicy(.regular)
            preview.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            preview.window!.appearance = NSAppearance(named: appearance)
            let view = preview.window!.contentView!
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/screenshot-\(appearance.rawValue).png"))
        }
        preview.close()
        let suite = "screenshot.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ScreenshotManager(defaults: defaults)
        manager.conflicts = { _ in true }
        precondition(!manager.setShortcut(ScreenshotManager.defaultShortcut))
        precondition(manager.shortcut == ScreenshotManager.defaultShortcut)
        precondition(manager.setShortcut(nil) && manager.shortcut == nil)
        precondition(ScreenshotManager(defaults: defaults).shortcut == nil)
        manager.stop()
        print("PASS: screenshot export dimensions, opaque cover, undo/redo, light/dark editor, shortcut conflict and persistence")
    }
}
