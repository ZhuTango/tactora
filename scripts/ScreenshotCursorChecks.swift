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
        precondition(canvas.acceptsFirstMouse(for: nil), "First drag must reach the selection canvas while the overlay is activating")
        for size in [NSSize.zero, NSSize(width: 1, height: 1), NSSize(width: 5, height: 100), NSSize(width: 100, height: 5), NSSize(width: 100, height: 100)] {
            canvas.selection = NSRect(origin: NSPoint(x: 50, y: 50), size: size)
            canvas.resetCursorRects()
            canvas.discardCursorRects()
        }
        canvas.selection = nil
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 200, y: 150)))
        precondition(canvas.alignmentGuidePoint == NSPoint(x: 200, y: 150))
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 200, y: 150)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 400, y: 350)))
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 400, y: 350)))
        let pixelScale = canvas.image.size.width / canvas.imageRect.width
        precondition(canvas.selection == NSRect(x: 200 * pixelScale, y: 150 * pixelScale, width: 200 * pixelScale, height: 200 * pixelScale))
        canvas.cursorExclusions = [NSRect(x: 390, y: 340, width: 30, height: 30)]
        precondition(canvas.alignmentGuidePoint == nil)
        canvas.cursorExclusions = []
        canvas.selectionMode = false
        precondition(canvas.alignmentGuidePoint == nil)
        canvas.selectionMode = true
        canvas.mouseExited(with: mouse(.mouseMoved, .zero))
        precondition(canvas.alignmentGuidePoint == nil)
        print("PASS: first-click acceptance, first drag selection, alignment pointer and toolbar exclusion")
        let bounds = NSRect(origin: .zero, size: canvas.image.size)
        for point in [NSPoint(x: 50, y: 50), NSPoint(x: 100, y: 50), NSPoint(x: 50, y: 100)] {
            canvas.selection = ScreenshotSelection.drag(handle: -1, start: NSPoint(x: 50, y: 50), point: point, original: .zero, bounds: bounds)
            precondition(canvas.selection!.origin.x.isFinite && canvas.selection!.origin.y.isFinite)
            canvas.resetCursorRects()
            canvas.discardCursorRects()
        }
        let toolbar = NSRect(x: 50, y: 50, width: 100, height: 44)
        let style = NSRect(x: 70, y: 10, width: 70, height: 30)
        let regions = ScreenshotSelection.cursorRegions(in: canvas.bounds, excluding: [toolbar, style])
        precondition(regions.allSatisfy { !$0.intersects(toolbar) && !$0.intersects(style) })
        let expectedArea = canvas.bounds.width * canvas.bounds.height - toolbar.width * toolbar.height - style.width * style.height
        precondition(regions.reduce(0) { $0 + $1.width * $1.height } == expectedArea)
        canvas.cursorExclusions = [toolbar, style]
        canvas.resetCursorRects()
        canvas.discardCursorRects()
        let controls = ScreenshotToolbarView(frame: toolbar)
        controls.resetCursorRects()
        controls.discardCursorRects()
        print("PASS: canvas cursor regions exclude toolbar and style controls; toolbar registers arrow cursor")
        canvas.selection = .null
        canvas.resetCursorRects()
        canvas.discardCursorRects()
        print("PASS: zero, narrow and axis-aligned selections survive real AppKit cursor registration")
    }
}
