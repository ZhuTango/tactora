import AppKit

@main struct ScreenshotAnnotationChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<128 {
            for x in 0..<128 { bitmap.setColor(x.isMultiple(of: 2) ? NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1) : NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(bitmap)
        let canvas = ScreenshotCanvas(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.contentScale = 2
        canvas.textSize = 18
        canvas.beginText(at: NSPoint(x: 20, y: 100))
        let field = canvas.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(abs(field.font!.pointSize - 18) < 0.01, "Text uses explicit points, independent of screen resolution")
        precondition(!field.isBezeled && !field.drawsBackground)
        field.stringValue = "中A"
        canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let expectedX = (field.frame.minX + 2 - canvas.imageRect.minX) * 2
        let expectedY = (field.frame.minY + 2 - canvas.imageRect.minY) * 2
        canvas.commitText()
        let text = canvas.annotations.last!
        precondition(text.fontSize == 36 && text.start == NSPoint(x: expectedX, y: expectedY))
        canvas.tool = .text
        let textClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: text.start.x / 2 + 2, y: text.start.y / 2 + 2), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: textClick)
        precondition(canvas.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "中A", "Clicking existing text must edit it instead of overlaying a new input")
        let editingField = canvas.subviews.compactMap { $0 as? NSTextField }.first!
        editingField.stringValue = "再次编辑"
        canvas.commitText()
        precondition(canvas.annotations.count == 1 && canvas.annotations[0].text == "再次编辑" && canvas.annotations[0].start == text.start)
        canvas.undoAnnotation()
        precondition(canvas.annotations[0].text == "中A")
        canvas.redoAnnotation()
        precondition(canvas.annotations[0].text == "再次编辑")
        canvas.undoAnnotation()
        canvas.undoAnnotation()
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for tool in [ScreenshotAnnotation.Tool.ellipse, .line, .pen, .highlight, .number] {
            canvas.tool = tool
            canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10, y: 10)))
            if tool != .number {
                canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 25, y: 35)))
                canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 40, y: 40)))
            }
            precondition(canvas.annotations.last?.tool == tool)
            if tool == .pen { precondition(canvas.annotations.last!.points.count >= 2) }
            precondition(canvas.pngData() != nil)
            canvas.undoAnnotation()
        }
        canvas.tool = .cover
        canvas.coverEffect = .pixelate
        canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 1, y: 1)))
        canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 60, y: 60)))
        canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 60, y: 60)))
        let output = NSBitmapImageRep(data: canvas.pngData()!)!
        let first = output.colorAt(x: 30, y: 30)!.usingColorSpace(.deviceRGB)!
        let second = output.colorAt(x: 31, y: 30)!.usingColorSpace(.deviceRGB)!
        precondition(first.redComponent + first.blueComponent > 0.5, "Mosaic preserves pixelated image colors rather than producing black blocks")
        precondition(abs(first.redComponent - second.redComponent) < 0.01, "Adjacent source stripes become one mosaic block")
        canvas.undoAnnotation()
        canvas.coverEffect = .solid
        canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 1, y: 1)))
        canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 60, y: 60)))
        let solid = NSBitmapImageRep(data: canvas.pngData()!)!.colorAt(x: 30, y: 30)!.usingColorSpace(.deviceRGB)!
        precondition(solid.redComponent < 0.01 && solid.blueComponent < 0.01 && solid.alphaComponent == 1)
        print("PASS: stable point-size text and export anchor, ellipse/line/pen/highlight/number input, colored mosaic and opaque cover")
    }
}
