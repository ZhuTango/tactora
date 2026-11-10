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
        for effect in [ScreenshotAnnotation.CoverEffect.pixelate, .solid] {
            let editable = ScreenshotCanvas(image: image)
            let editWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 256, height: 256), styleMask: [.borderless], backing: .buffered, defer: false)
            editWindow.isReleasedWhenClosed = false
            editWindow.contentView = editable
            editable.tool = .cover
            editable.append(ScreenshotAnnotation(tool: .cover, start: NSPoint(x: 20, y: 20), end: NSPoint(x: 50, y: 50), coverEffect: effect))
            func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
                let scale = editable.imageRect.width / editable.image.size.width
                return NSEvent.mouseEvent(with: type, location: NSPoint(x: editable.imageRect.minX + x * scale, y: editable.imageRect.minY + y * scale), modifierFlags: [], timestamp: 0, windowNumber: editWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            editable.mouseDown(with: event(.leftMouseDown, 35, 35))
            editable.mouseDragged(with: event(.leftMouseDragged, 45, 45))
            editable.mouseUp(with: event(.leftMouseUp, 45, 45))
            precondition(editable.annotations.count == 1 && editable.annotations[0].rect == NSRect(x: 30, y: 30, width: 30, height: 30))
            editable.undoAnnotation()
            precondition(editable.annotations[0].rect == NSRect(x: 20, y: 20, width: 30, height: 30))
            editable.redoAnnotation()
            editable.mouseDown(with: event(.leftMouseDown, 45, 45))
            editable.mouseUp(with: event(.leftMouseUp, 45, 45))
            editable.mouseDown(with: event(.leftMouseDown, 60, 60))
            editable.mouseDragged(with: event(.leftMouseDragged, 80, 90))
            editable.mouseUp(with: event(.leftMouseUp, 80, 90))
            precondition(editable.annotations[0].rect == NSRect(x: 30, y: 30, width: 50, height: 60))
            precondition(editable.annotations[0].coverEffect == effect)
            let output = NSBitmapImageRep(data: editable.renderedImage()!.tiffRepresentation!)!
            precondition(output.colorAt(x: 25, y: 25)!.blueComponent > 0.9)
            if effect == .solid { precondition(output.colorAt(x: 45, y: 70)!.redComponent < 0.01) }
            editable.undoAnnotation()
            precondition(editable.annotations[0].rect == NSRect(x: 30, y: 30, width: 30, height: 30))
            editable.mouseDown(with: event(.leftMouseDown, 45, 45))
            editable.mouseUp(with: event(.leftMouseUp, 45, 45))
            editable.setCoverTint(.green)
            precondition(editable.annotations[0].coverTint == NSColor.green)
            let tinted = NSBitmapImageRep(data: editable.pngData()!)!.colorAt(x: 45, y: 83)!.usingColorSpace(.deviceRGB)!
            precondition(tinted.greenComponent > 0.3)
            editable.undoAnnotation()
            precondition(editable.annotations[0].coverTint == nil)
            editable.selectionEnabled = true
            editable.selection = NSRect(x: 10, y: 10, width: 90, height: 90)
            editable.mouseDown(with: event(.leftMouseDown, 120, 120))
            editable.mouseUp(with: event(.leftMouseUp, 120, 120))
            precondition(editable.selection == NSRect(x: 10, y: 10, width: 90, height: 90), "An outside click must preserve the selection and toolbar")
            editWindow.close()
        }
        let redactionImage = NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 128, height: 128))
        let protectedCanvas = ScreenshotCanvas(image: redactionImage)
        protectedCanvas.append(ScreenshotAnnotation(tool: .cover, start: .zero, end: NSPoint(x: 128, y: 128), coverEffect: .solid))
        protectedCanvas.append(ScreenshotAnnotation(tool: .cover, start: NSPoint(x: 40, y: 40), end: NSPoint(x: 90, y: 90), coverEffect: .pixelate))
        let protectedPixel = NSBitmapImageRep(data: protectedCanvas.pngData()!)!.colorAt(x: 64, y: 64)!.usingColorSpace(.deviceRGB)!
        precondition(protectedPixel.redComponent < 0.01 && protectedPixel.blueComponent < 0.01, "Mosaic overlap must preserve an existing opaque redaction")

        protectedCanvas.undoAnnotation()
        protectedCanvas.append(ScreenshotAnnotation(tool: .cover, start: NSPoint(x: 20, y: 20), end: NSPoint(x: 50, y: 50), coverEffect: .solid, coverTint: .green))
        let coveredBefore = NSBitmapImageRep(data: protectedCanvas.pngData()!)!
        protectedCanvas.append(ScreenshotAnnotation(tool: .cover, start: .zero, end: NSPoint(x: 128, y: 128), coverEffect: .pixelate, coverTint: .red))
        let coveredAfter = NSBitmapImageRep(data: protectedCanvas.pngData()!)!
        for y in 0..<128 {
            for x in 0..<128 {
                precondition(coveredBefore.colorAt(x: x, y: y) == coveredAfter.colorAt(x: x, y: y), "Multiple overlapping covers must stay protected even under tinted mosaic")
            }
        }
        let mosaicCanvas = ScreenshotCanvas(image: redactionImage)
        mosaicCanvas.append(ScreenshotAnnotation(tool: .cover, start: .zero, end: NSPoint(x: 128, y: 128), coverEffect: .pixelate, pixelSize: 32))
        let mosaicBefore = mosaicCanvas.pngData()!
        mosaicCanvas.append(ScreenshotAnnotation(tool: .cover, start: .zero, end: NSPoint(x: 128, y: 128), coverEffect: .pixelate, pixelSize: 4))
        precondition(mosaicBefore == mosaicCanvas.pngData()!, "A weaker overlapping mosaic must not reveal more of the original image")

        let dragging = ScreenshotCanvas(image: image)
        let dragWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 128), styleMask: [.borderless], backing: .buffered, defer: false)
        dragWindow.isReleasedWhenClosed = false
        dragWindow.contentView = dragging
        dragging.tool = .cover
        let cover = ScreenshotAnnotation(tool: .cover, start: NSPoint(x: 10, y: 10), end: NSPoint(x: 50, y: 50))
        func dragEvent(_ type: NSEvent.EventType, _ coordinate: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: coordinate, y: coordinate), modifierFlags: [], timestamp: 0, windowNumber: dragWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        dragging.append(cover)
        dragging.mouseDown(with: dragEvent(.leftMouseDown, 30))
        dragging.mouseDragged(with: dragEvent(.leftMouseDragged, 35))
        dragging.undoAnnotation()
        dragging.mouseDragged(with: dragEvent(.leftMouseDragged, 40))
        dragging.mouseUp(with: dragEvent(.leftMouseUp, 40))
        precondition(dragging.annotations.isEmpty, "Undo during drag must remove the cover without stale drag writes")
        dragging.redoAnnotation()
        let restored = dragging.annotations[0].rect
        dragging.mouseDown(with: dragEvent(.leftMouseDown, 35))
        dragging.undoAnnotation()
        dragging.redoAnnotation()
        dragging.mouseUp(with: dragEvent(.leftMouseUp, 45))
        precondition(dragging.annotations[0].rect == restored, "Redo must not resume an invalidated drag")
        dragWindow.close()
        print("PASS: overlapping redactions remain opaque; undo/redo during cover drag is safe")
        print("PASS: mosaic and solid cover move, resize, unchanged effect, exported position and single-step undo/redo")
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
