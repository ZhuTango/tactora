import AppKit

@main struct ScreenshotCursorChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 800, height: 600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 600).fill()
        image.unlockFocus()
        let canvas = ScreenshotCanvas(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.selectionEnabled = true
        for size in [NSSize.zero, NSSize(width: 1, height: 1), NSSize(width: 5, height: 100), NSSize(width: 100, height: 5), NSSize(width: 100, height: 100)] {
            canvas.selection = NSRect(origin: NSPoint(x: 50, y: 50), size: size)
            canvas.resetCursorRects()
            canvas.discardCursorRects()
        }
        let bounds = NSRect(origin: .zero, size: canvas.image.size)
        for point in [NSPoint(x: 50, y: 50), NSPoint(x: 100, y: 50), NSPoint(x: 50, y: 100)] {
            canvas.selection = ScreenshotSelection.drag(handle: -1, start: NSPoint(x: 50, y: 50), point: point, original: .zero, bounds: bounds)
            precondition(canvas.selection!.origin.x.isFinite && canvas.selection!.origin.y.isFinite)
            canvas.resetCursorRects()
            canvas.discardCursorRects()
        }
        canvas.selection = .null
        canvas.resetCursorRects()
        canvas.discardCursorRects()
        print("PASS: zero, narrow and axis-aligned selections survive real AppKit cursor registration")
    }
}
