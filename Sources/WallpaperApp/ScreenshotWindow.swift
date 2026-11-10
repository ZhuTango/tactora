import AppKit
import UniformTypeIdentifiers
import CoreImage

struct ScreenshotAnnotation {
    enum Tool: Int, CaseIterable { case arrow, rectangle, text, cover, ellipse, line, pen, highlight, number }
    enum CoverEffect { case solid, pixelate }
    let tool: Tool
    var start: NSPoint
    var end: NSPoint
    var text = ""
    var color: NSColor = .systemRed
    var thickness: CGFloat = 1
    var strokeWidth: CGFloat = 3
    var fontSize: CGFloat = 18
    var points: [NSPoint] = []
    var coverEffect: CoverEffect = .solid
    var pixelSize: CGFloat = 16
    var rect: NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

@MainActor
final class ScreenshotCanvas: NSView, NSTextFieldDelegate {
    let image: NSImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private var undoStates: [[ScreenshotAnnotation]] = []
    private var redoStates: [[ScreenshotAnnotation]] = []
    private var editingTextIndex: Int?
    private var draft: ScreenshotAnnotation?
    var editing = true
    var color: NSColor = .systemRed
    var thickness: CGFloat = 1
    var contentScale: CGFloat = 1
    var textSize: CGFloat = 18
    var coverEffect: ScreenshotAnnotation.CoverEffect = .pixelate
    private var pixelatedImages: [Int: NSImage] = [:]
    private let imageContext = CIContext(options: [.useSoftwareRenderer: false])
    private var textEditor: NSTextField?
    private var textOrigin = NSPoint.zero
    var cursorExclusions: [NSRect] = []
    var selectionEnabled = false
    var selectionMode = true { didSet { needsDisplay = true } }
    private var alignmentTrackingArea: NSTrackingArea?
    private var pointerLocation: NSPoint?
    var selection: NSRect? {
        didSet { needsDisplay = true; onSelectionChange?() }
    }
    var onSelectionChange: (() -> Void)?
    private var selectionDrag: (handle: Int, start: NSPoint, original: NSRect)?
    private var selectedCoverIndex: Int?
    private var coverDrag: (index: Int, handle: Int, start: NSPoint, original: NSRect, before: [ScreenshotAnnotation])?
    var tool = ScreenshotAnnotation.Tool.arrow { didSet { selectedCoverIndex = nil; needsDisplay = true } }
    var onChange: (() -> Void)?

    init(image: NSImage) {
        // Use pixel coordinates throughout, preserving Retina resolution on export.
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else { self.image = image }
        super.init(frame: .zero)
        contentScale = self.image.size.width / max(1, image.size.width)
        setAccessibilityLabel(AppLanguage.english ? "Screenshot canvas" : "截图画布")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    var imageRect: NSRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let rect = imageRect
        guard rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / image.size.width)
        transform.concat()
        drawImage(includingDraft: true)
        NSGraphicsContext.restoreGraphicsState()
        if selectionEnabled { drawSelection() }
        drawCoverControls()
        if let point = alignmentGuidePoint {
            let lines = NSBezierPath()
            lines.move(to: NSPoint(x: bounds.minX, y: point.y))
            lines.line(to: NSPoint(x: bounds.maxX, y: point.y))
            lines.move(to: NSPoint(x: point.x, y: bounds.minY))
            lines.line(to: NSPoint(x: point.x, y: bounds.maxY))
            NSColor.black.withAlphaComponent(0.6).setStroke()
            lines.lineWidth = 3
            lines.stroke()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            lines.lineWidth = 1
            lines.stroke()
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { selectionEnabled }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let alignmentTrackingArea { removeTrackingArea(alignmentTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        alignmentTrackingArea = area
        if let window { pointerLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil) }
    }
    var alignmentGuidePoint: NSPoint? {
        guard selectionEnabled, selectionMode, let point = pointerLocation,
              bounds.contains(point), !cursorExclusions.contains(where: { $0.contains(point) }) else { return nil }
        if selectionDrag?.handle == -2 { return nil }
        if selectionDrag == nil, let rect = selectionViewRect, rect.insetBy(dx: 8, dy: 8).contains(point) { return nil }
        return point
    }
    private func trackPointer(_ event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) { trackPointer(event) }
    override func mouseEntered(with event: NSEvent) { trackPointer(event) }
    override func mouseExited(with event: NSEvent) { pointerLocation = nil; needsDisplay = true }
    var selectionViewRect: NSRect? {
        guard let selection, !selection.isEmpty,
              selection.origin.x.isFinite, selection.origin.y.isFinite,
              selection.width.isFinite, selection.height.isFinite,
              imageRect.width > 0 else { return nil }
        let scale = imageRect.width / image.size.width
        return NSRect(x: imageRect.minX + selection.minX * scale, y: imageRect.minY + selection.minY * scale,
                      width: selection.width * scale, height: selection.height * scale)
    }
    private func drawSelection() {
        let shade = NSBezierPath(rect: bounds)
        if let rect = selectionViewRect {
            shade.appendRect(rect)
            shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        shade.fill()
        guard let rect = selectionViewRect else { return }
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()
        for point in ScreenshotSelection.handles(rect) {
            let handle = NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }
    private var selectedCoverRect: NSRect? {
        guard tool == .cover, !selectionMode || !selectionEnabled,
              let index = selectedCoverIndex, annotations.indices.contains(index), annotations[index].tool == .cover else { return nil }
        let rect = annotations[index].rect
        let scale = imageRect.width / image.size.width
        return NSRect(x: imageRect.minX + rect.minX * scale, y: imageRect.minY + rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }
    private func drawCoverControls() {
        guard let rect = selectedCoverRect else { return }
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()
        for point in ScreenshotSelection.handles(rect) {
            let handle = NSBezierPath(rect: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1
            handle.stroke()
        }
    }
    private func beginCoverDrag(at point: NSPoint) -> Bool {
        guard tool == .cover, !selectionEnabled || !selectionMode else { return false }
        let tolerance = 6 * image.size.width / max(1, imageRect.width)
        if let index = selectedCoverIndex, annotations.indices.contains(index),
           let handle = ScreenshotSelection.hitHandle(point, rect: annotations[index].rect, tolerance: tolerance) {
            coverDrag = (index, handle, point, annotations[index].rect, annotations)
            return true
        }
        guard let index = annotations.lastIndex(where: { $0.tool == .cover && $0.rect.contains(point) }) else {
            selectedCoverIndex = nil
            return false
        }
        selectedCoverIndex = index
        coverDrag = (index, -2, point, annotations[index].rect, annotations)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return true
    }
    private func drawImage(includingDraft: Bool) {
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        if selectionEnabled, let selection { NSBezierPath(rect: selection).addClip() }
        let items = annotations + (includingDraft ? draft.map { [$0] } ?? [] : [])
        for (index, item) in items.enumerated() {
            if includingDraft && index == editingTextIndex { continue }
            let lineWidth = item.strokeWidth * item.thickness
            item.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            switch item.tool {
            case .cover:
                if item.coverEffect == .pixelate, let mosaic = pixelatedImage(blockSize: item.pixelSize) {
                    mosaic.draw(in: item.rect, from: item.rect, operation: .copy, fraction: 1)
                } else {
                    NSColor.black.setFill()
                    item.rect.fill()
                }
            case .rectangle:
                path.appendRect(item.rect); path.stroke()
            case .ellipse:
                path.appendOval(in: item.rect)
                path.stroke()
            case .line:
                path.move(to: item.start)
                path.line(to: item.end)
                path.stroke()
            case .pen:
                path.move(to: item.start)
                for point in item.points { path.line(to: point) }
                path.stroke()
            case .highlight:
                item.color.withAlphaComponent(0.28).setFill()
                item.rect.fill()
            case .number:
                let diameter = item.fontSize * 1.65
                let circle = NSRect(x: item.start.x - diameter / 2, y: item.start.y - diameter / 2, width: diameter, height: diameter)
                item.color.setFill()
                NSBezierPath(ovalIn: circle).fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: item.fontSize, weight: .semibold), .foregroundColor: NSColor.white]
                let size = (item.text as NSString).size(withAttributes: attributes)
                (item.text as NSString).draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
            case .arrow:
                path.move(to: item.start); path.line(to: item.end)
                let angle = atan2(item.end.y - item.start.y, item.end.x - item.start.x)
                let head = min(hypot(item.end.x - item.start.x, item.end.y - item.start.y) / 2, lineWidth * 5)
                for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: item.end)
                    path.line(to: NSPoint(x: item.end.x - head * cos(angle + delta), y: item.end.y - head * sin(angle + delta)))
                }
                path.stroke()
            case .text:
                let font = NSFont.systemFont(ofSize: item.fontSize, weight: .medium)
                (item.text as NSString).draw(at: item.start, withAttributes: [.font: font, .foregroundColor: item.color])
            }
        }
    }
    private func pixelatedImage(blockSize: CGFloat) -> NSImage? {
        let size = max(4, Int(blockSize.rounded()))
        if let cached = pixelatedImages[size] { return cached }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let source = CIImage(cgImage: cg)
        let output = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: size]).cropped(to: source.extent)
        guard let result = imageContext.createCGImage(output, from: source.extent) else { return nil }
        let mosaic = NSImage(cgImage: result, size: image.size)
        pixelatedImages[size] = mosaic
        return mosaic
    }
    private func annotation(at point: NSPoint) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, start: point, end: point, color: color, thickness: thickness,
                             strokeWidth: 3 * contentScale, fontSize: textSize * contentScale,
                             coverEffect: coverEffect, pixelSize: 12 * contentScale * thickness)
    }
    func renderedImage() -> NSImage? {
        if selectionEnabled && selection == nil { return nil }
        let crop = (selectionEnabled ? selection! : NSRect(origin: .zero, size: image.size)).integral.intersection(NSRect(origin: .zero, size: image.size))
        let size = crop.size
        guard size.width >= 1, size.height >= 1,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let translation = NSAffineTransform()
        translation.translateX(by: -crop.minX, yBy: -crop.minY)
        translation.concat()
        drawImage(includingDraft: false)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        return result
    }
    func pngData() -> Data? {
        guard let image = renderedImage(), let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    private func point(for event: NSEvent, clamp: Bool) -> NSPoint? {
        let location = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, clamp || rect.contains(location) else { return nil }
        return NSPoint(x: min(image.size.width, max(0, (location.x - rect.minX) * image.size.width / rect.width)),
                       y: min(image.size.height, max(0, (location.y - rect.minY) * image.size.height / rect.height)))
    }
    override func mouseDown(with event: NSEvent) {
        trackPointer(event)
        guard editing, let point = point(for: event, clamp: false) else { return }
        commitText()
        window?.makeFirstResponder(self)
        if beginCoverDrag(at: point) { return }
        if selectionEnabled {
            let rect = selection ?? .zero
            let tolerance = 8 * image.size.width / max(1, imageRect.width)
            let handle = ScreenshotSelection.hitHandle(point, rect: rect, tolerance: tolerance)
            if selection == nil || handle != nil || selectionMode || !rect.contains(point) {
                let mode = handle ?? (rect.contains(point) ? -2 : -1)
                selectionDrag = (mode, point, rect)
                if mode == -1 { selection = NSRect(origin: point, size: .zero) }
                return
            }
        }
        if tool == .text {
            if let index = annotations.lastIndex(where: { item in
                guard item.tool == .text else { return false }
                let size = (item.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: item.fontSize, weight: .medium)])
                return NSRect(origin: item.start, size: size).insetBy(dx: -4, dy: -4).contains(point)
            }) {
                beginEditingText(at: index)
            } else { beginText(at: point) }
            return
        }
        var item = annotation(at: point)
        if tool == .number {
            item.text = String(annotations.filter { $0.tool == .number }.count + 1)
            append(item)
            return
        }
        draft = item
    }
    override func mouseDragged(with event: NSEvent) {
        trackPointer(event)
        if let drag = coverDrag, let point = point(for: event, clamp: true) {
            let bounds = NSRect(origin: .zero, size: image.size)
            let rect = ScreenshotSelection.drag(handle: drag.handle, start: drag.start, point: point, original: drag.original, bounds: bounds)
            annotations[drag.index].start = rect.origin
            annotations[drag.index].end = NSPoint(x: rect.maxX, y: rect.maxY)
            needsDisplay = true
            return
        }
        if let drag = selectionDrag, let point = point(for: event, clamp: true) {
            selection = ScreenshotSelection.drag(handle: drag.handle, start: drag.start, point: point, original: drag.original, bounds: NSRect(origin: .zero, size: image.size))
            return
        }
        guard var draft, let point = point(for: event, clamp: true) else { return }
        draft.end = point
        if draft.tool == .pen { draft.points.append(point) }
        self.draft = draft
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let drag = coverDrag {
            mouseDragged(with: event)
            coverDrag = nil
            if annotations[drag.index].rect != drag.original {
                undoStates.append(drag.before)
                redoStates.removeAll()
                onChange?()
            }
            window?.invalidateCursorRects(for: self)
            return
        }
        if selectionDrag != nil {
            mouseDragged(with: event)
            selectionDrag = nil
            if let selection, selection.width < 2 || selection.height < 2 { self.selection = nil }
            return
        }
        guard var draft else { return }
        self.draft = nil
        if let point = point(for: event, clamp: true), hypot(point.x - draft.start.x, point.y - draft.start.y) >= 2 || !draft.points.isEmpty {
            draft.end = point
            if draft.tool == .pen { draft.points.append(point) }
            append(draft)
            if draft.tool == .cover { selectedCoverIndex = annotations.count - 1 }
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        guard !imageRect.isEmpty, imageRect.origin.x.isFinite, imageRect.origin.y.isFinite,
              imageRect.width.isFinite, imageRect.height.isFinite else { return }
        registerCanvasCursor(imageRect, cursor: selectionEnabled && selectionMode ? .crosshair : tool == .text ? .iBeam : .crosshair)
        if selectionEnabled, let rect = selectionViewRect {
            // CGRect.insetBy returns a null rect with infinite origin when it collapses.
            if selectionMode, rect.width > 16, rect.height > 16 {
                registerCanvasCursor(rect.insetBy(dx: 8, dy: 8), cursor: .openHand)
            }
            registerCanvasCursor(NSRect(x: rect.minX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
            registerCanvasCursor(NSRect(x: rect.maxX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
            registerCanvasCursor(NSRect(x: rect.minX, y: rect.minY - 5, width: rect.width, height: 10), cursor: .resizeUpDown)
            registerCanvasCursor(NSRect(x: rect.minX, y: rect.maxY - 5, width: rect.width, height: 10), cursor: .resizeUpDown)
        }
        if tool == .cover, !selectionEnabled || !selectionMode {
            let scale = imageRect.width / image.size.width
            for item in annotations where item.tool == .cover {
                let rect = NSRect(x: imageRect.minX + item.rect.minX * scale, y: imageRect.minY + item.rect.minY * scale, width: item.rect.width * scale, height: item.rect.height * scale)
                registerCanvasCursor(rect, cursor: .openHand)
            }
            if let rect = selectedCoverRect {
                for (index, point) in ScreenshotSelection.handles(rect).enumerated() {
                    registerCanvasCursor(NSRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12), cursor: [1, 5].contains(index) ? .resizeUpDown : .resizeLeftRight)
                }
            }
        }
    }
    private func registerCanvasCursor(_ rect: NSRect, cursor: NSCursor) {
        for region in ScreenshotSelection.cursorRegions(in: rect, excluding: cursorExclusions) {
            addCursorRect(region, cursor: cursor)
        }
    }
    func beginText(at point: NSPoint) {
        commitText()
        textOrigin = point
        let field = NSTextField()
        field.placeholderString = AppLanguage.english ? "Type text" : "输入文字"
        field.font = .systemFont(ofSize: max(1, textSize * contentScale * imageRect.width / image.size.width), weight: .medium)
        field.textColor = color
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.target = self
        field.action = #selector(finishText)
        field.setAccessibilityLabel(AppLanguage.english ? "Annotation text" : "标注文字")
        textEditor = field
        addSubview(field)
        layoutTextEditor()
        window?.makeFirstResponder(field)
    }
    func beginEditingText(at index: Int) {
        commitText()
        guard annotations.indices.contains(index), annotations[index].tool == .text else { return }
        let item = annotations[index]
        color = item.color
        textSize = item.fontSize / contentScale
        let font = NSFont.systemFont(ofSize: item.fontSize, weight: .medium)
        beginText(at: NSPoint(x: item.start.x, y: item.start.y + font.ascender - font.descender + 4 * contentScale))
        editingTextIndex = index
        textEditor?.stringValue = item.text
        layoutTextEditor()
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        layoutTextEditor()
    }
    private func layoutTextEditor() {
        guard let field = textEditor else { return }
        let rect = selectionViewRect ?? imageRect
        let scale = imageRect.width / image.size.width
        guard scale > 0 else { return }
        let measured = ((field.stringValue.isEmpty ? "输入文字" : field.stringValue) as NSString).size(withAttributes: [.font: field.font!])
        let width = min(rect.width, max(90, measured.width + 12))
        let height = min(rect.height, ceil(field.font!.ascender - field.font!.descender + field.font!.leading) + 4)
        let x = min(rect.maxX - width, max(rect.minX, imageRect.minX + textOrigin.x * scale))
        let y = min(rect.maxY - height, max(rect.minY, imageRect.minY + textOrigin.y * scale - height))
        field.frame = NSRect(x: x, y: y, width: width, height: height)
    }
    func controlTextDidChange(_ notification: Notification) { layoutTextEditor() }
    @objc private func finishText() { commitText() }
    func commitText() {
        guard let field = textEditor else { return }
        let value = field.stringValue
        let scale = max(0.001, imageRect.width / image.size.width)
        let position = NSPoint(x: (field.frame.minX + 2 - imageRect.minX) / scale,
                               y: (field.frame.minY + 2 - imageRect.minY) / scale)
        textEditor = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if let index = editingTextIndex {
            editingTextIndex = nil
            if value != annotations[index].text {
                undoStates.append(annotations)
                redoStates.removeAll()
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    annotations.remove(at: index)
                } else { annotations[index].text = value }
                onChange?()
            }
            needsDisplay = true
        } else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(ScreenshotAnnotation(tool: .text, start: position, end: position, text: value, color: color, fontSize: textSize * contentScale))
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        textEditor?.removeFromSuperview()
        textEditor = nil
        editingTextIndex = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
        return true
    }
    func append(_ annotation: ScreenshotAnnotation) {
        undoStates.append(annotations)
        annotations.append(annotation)
        redoStates.removeAll()
        needsDisplay = true
        onChange?()
    }
    func undoAnnotation() {
        guard let state = undoStates.popLast() else { return }
        redoStates.append(annotations)
        annotations = state
        selectedCoverIndex = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onChange?()
    }
    func redoAnnotation() {
        guard let state = redoStates.popLast() else { return }
        undoStates.append(annotations)
        annotations = state
        selectedCoverIndex = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onChange?()
    }
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
}

@MainActor
final class ScreenshotToolButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var hovered = false
    override var state: NSControl.StateValue { didSet { refreshBackground() } }
    override var isEnabled: Bool { didSet { refreshBackground() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshBackground() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshBackground() }
    func refreshBackground() {
        let selected = state == .on
        let color = selected ? NSColor.controlAccentColor : NSColor.labelColor
        let alpha: CGFloat = !isEnabled ? 0 : (hovered ? (selected ? 0.32 : 0.14) : (selected ? 0.16 : 0))
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor }
    }
}

@MainActor
final class ScreenshotToolbarView: NSVisualEffectView {
    override func resetCursorRects() {
        super.resetCursorRects()
        if !bounds.isEmpty { addCursorRect(bounds, cursor: .arrow) }
    }
}

@MainActor
private final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ScreenshotWindow: NSWindowController, NSWindowDelegate {
    let canvas: ScreenshotCanvas
    var onClose: (() -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onOCR: ((Data) -> Void)?
    var onSession: ((ScreenshotSession.Mode, NSScreen, CGRect, Int) -> Void)? {
        didSet { sessionButtons.forEach { $0.isEnabled = captureScreen != nil && onSession != nil } }
    }
    private var sessionButtons: [NSButton] = []
    private let captureScreen: NSScreen?
    private var appearanceOptions: ScreenshotAppearance?
    private var appearanceSheet: ScreenshotAppearanceSheet?
    private let feedback = NSTextField(labelWithString: "")
    private var undoButton: NSButton!
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var selectedColor = 0
    private let palette = NSStackView()
    private let textSizePicker = NSPopUpButton()
    private let coverPicker = NSPopUpButton()
    private let options = NSStackView()
    private var redoButton: NSButton!
    private let widthPicker = NSPopUpButton()
    private var floatingControls: NSView?
    private var floatingStyle: NSView?
    private var selectionButton: NSButton?
    private var selectionHint: NSTextField?
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemBlue, .systemGreen, .white, .black]

    init(image: NSImage, captureScreen: NSScreen? = nil, selectWhole: Bool = false) {
        self.captureScreen = captureScreen
        canvas = ScreenshotCanvas(image: image)
        canvas.selectionEnabled = captureScreen != nil
        if let captureScreen { canvas.contentScale = captureScreen.backingScaleFactor }
        if selectWhole { canvas.selection = NSRect(origin: .zero, size: canvas.image.size) }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let available = NSSize(width: min(1100, area.width - 48), height: min(800, area.height - 80))
        let scale = min(1, min((available.width - 24) / image.size.width, (available.height - 100) / image.size.height))
        let size = NSSize(width: max(808, image.size.width * scale + 24), height: max(220, image.size.height * scale + 100))
        let panel = ScreenshotPanel(contentRect: captureScreen?.frame ?? NSRect(origin: .zero, size: size), styleMask: captureScreen == nil ? [.titled, .closable, .resizable, .utilityWindow] : [.borderless], backing: .buffered, defer: false)
        panel.title = AppLanguage.english ? "Screenshot" : "截图"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = captureScreen == nil ? .floating : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.minSize = NSSize(width: 808, height: 220)
        super.init(window: panel)
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let root = NSView()
        panel.contentView = root
        let toolbar = NSStackView()
        toolbar.spacing = 4
        if captureScreen != nil {
            let pointer = iconButton("cursorarrow", label: AppLanguage.english ? "Move selection · V" : "移动选区 · V", action: #selector(selectRegion))
            pointer.identifier = NSUserInterfaceItemIdentifier("screenshot.select")
            pointer.setButtonType(.toggle)
            pointer.state = .on
            selectionButton = pointer
            toolbar.addArrangedSubview(pointer)
        }
        let definitions: [(ScreenshotAnnotation.Tool, String, String, String)] = [
            (.rectangle, "rectangle", "矩形 · R", "Rectangle · R"),
            (.ellipse, "circle", "圆形 · E", "Ellipse · E"),
            (.line, "line.diagonal", "直线 · L", "Line · L"),
            (.arrow, "arrow.up.right", "箭头 · A", "Arrow · A"),
            (.pen, "pencil.tip", "画笔 · B", "Pen · B"),
            (.highlight, "highlighter", "高亮 · H", "Highlight · H"),
            (.text, "textformat", "文字 · T", "Text · T"),
            (.number, "1.circle", "序号 · N", "Number · N"),
            (.cover, "square.grid.3x3.fill", "马赛克 / 遮挡 · X", "Mosaic / Cover · X")
        ]
        for (tool, symbol, chinese, english) in definitions {
            let button = iconButton(symbol, label: AppLanguage.english ? english : chinese, action: #selector(selectTool(_:)))
            button.tag = tool.rawValue
            button.identifier = NSUserInterfaceItemIdentifier("screenshot.tool.\(tool.rawValue)")
            button.setButtonType(.toggle)
            button.state = captureScreen == nil && tool == .arrow ? .on : .off
            toolbar.addArrangedSubview(button)
            toolButtons.append(button)
        }
        toolbar.addArrangedSubview(separator())
        undoButton = iconButton("arrow.uturn.backward", label: AppLanguage.english ? "Undo · ⌘Z" : "撤销 · ⌘Z", action: #selector(undoMark))
        toolbar.addArrangedSubview(undoButton)
        redoButton = iconButton("arrow.uturn.forward", label: AppLanguage.english ? "Redo · ⇧⌘Z" : "重做 · ⇧⌘Z", action: #selector(redoMark))
        toolbar.addArrangedSubview(redoButton)
        toolbar.addArrangedSubview(separator())
        toolbar.addArrangedSubview(iconButton("pin", label: AppLanguage.english ? "Pin · P" : "贴图 · P", action: #selector(pinImage)))
        toolbar.addArrangedSubview(iconButton("text.viewfinder", label: AppLanguage.english ? "Recognize text · O" : "识字 · O", action: #selector(recognize)))
        toolbar.addArrangedSubview(iconButton("square.and.arrow.down", label: AppLanguage.english ? "Save · ⌘S" : "保存 · ⌘S", action: #selector(saveImage)))
        let appearance = iconButton("wand.and.stars", label: AppLanguage.english ? "Watermark and style" : "水印与美化", action: #selector(editAppearance))
        appearance.identifier = NSUserInterfaceItemIdentifier("screenshot.appearance")
        toolbar.addArrangedSubview(appearance)
        for (title, symbol, tag) in [
            (AppLanguage.english ? "Scrolling capture" : "滚动截图", "scroll", 1),
            (AppLanguage.english ? "Record video" : "录制视频", "video", 2),
            (AppLanguage.english ? "Record GIF" : "录制 GIF", "photo.stack", 3)
        ] {
            let button = iconButton(symbol, label: title, action: #selector(startSession(_:)))
            button.tag = tag
            button.identifier = NSUserInterfaceItemIdentifier("screenshot.session.\(tag)")
            button.isEnabled = false
            sessionButtons.append(button)
            toolbar.addArrangedSubview(button)
        }
        toolbar.addArrangedSubview(separator())
        toolbar.addArrangedSubview(iconButton("xmark", label: AppLanguage.english ? "Cancel · Esc" : "取消 · Esc", action: #selector(cancelCapture)))
        let copy = iconButton("checkmark", label: AppLanguage.english ? "Copy and close · Enter" : "复制并关闭 · Enter", action: #selector(copyImage))
        copy.bezelStyle = .rounded
        copy.contentTintColor = .controlAccentColor
        copy.toolTip = AppLanguage.english ? "Copy and close · Enter / ⌘C" : "复制并关闭 · Enter / ⌘C"
        toolbar.addArrangedSubview(copy)
        let names = AppLanguage.english ? ["Red", "Orange", "Yellow", "Blue", "Green", "White", "Black"] : ["红色", "橙色", "黄色", "蓝色", "绿色", "白色", "黑色"]
        palette.spacing = 4
        for (index, color) in colors.enumerated() {
            let button = ScreenshotToolButton(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: names[index])!, target: self, action: #selector(changeColor(_:)))
            button.tag = index
            button.isBordered = false
            button.contentTintColor = color
            button.toolTip = names[index]
            button.setAccessibilityLabel(names[index])
            button.wantsLayer = true
            button.layer?.cornerRadius = 11
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            palette.addArrangedSubview(button)
            colorButtons.append(button)
        }
        widthPicker.addItems(withTitles: AppLanguage.english ? ["Thin", "Medium", "Thick"] : ["细", "中", "粗"])
        widthPicker.selectItem(at: 1)
        textSizePicker.addItems(withTitles: ["14 pt", "18 pt", "24 pt", "32 pt"])
        textSizePicker.selectItem(at: 1)
        coverPicker.addItems(withTitles: AppLanguage.english ? ["Mosaic", "Solid cover"] : ["马赛克", "纯色遮挡"])
        for picker in [widthPicker, textSizePicker, coverPicker] {
            picker.controlSize = .small
            picker.target = self
            picker.action = #selector(changeStyle)
            options.addArrangedSubview(picker)
        }
        widthPicker.setAccessibilityLabel(AppLanguage.english ? "Stroke / mosaic size" : "线宽 / 马赛克强度")
        textSizePicker.setAccessibilityLabel(AppLanguage.english ? "Font size" : "字号")
        coverPicker.setAccessibilityLabel(AppLanguage.english ? "Cover style" : "遮挡样式")
        options.insertArrangedSubview(palette, at: 0)
        options.spacing = 10
        options.detachesHiddenViews = true
        feedback.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        feedback.stringValue = "\(Int(canvas.image.size.width)) × \(Int(canvas.image.size.height)) px"
        let divider = NSBox()
        divider.boxType = .separator
        if captureScreen != nil {
            let card = floatingCard(size: NSSize(width: 808, height: 44))
            card.identifier = NSUserInterfaceItemIdentifier("screenshot.toolbar")
            floatingControls = card
            let style = floatingCard(size: NSSize(width: 188, height: 36))
            style.identifier = NSUserInterfaceItemIdentifier("screenshot.style")
            floatingStyle = style
            canvas.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(canvas)
            root.addSubview(card)
            root.addSubview(style)
            feedback.identifier = NSUserInterfaceItemIdentifier("screenshot.dimensions")
            feedback.textColor = .white
            feedback.backgroundColor = NSColor.black.withAlphaComponent(0.7)
            feedback.drawsBackground = true
            feedback.wantsLayer = true
            feedback.layer?.cornerRadius = 4
            feedback.layer?.masksToBounds = true
            root.addSubview(feedback)
            let hint = NSTextField(labelWithString: AppLanguage.english ? "Drag to select · F full screen · Esc cancel" : "拖动选择区域 · F 全屏 · Esc 取消")
            hint.font = .systemFont(ofSize: 13, weight: .medium)
            hint.textColor = .white
            hint.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(hint)
            selectionHint = hint
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 54)
            ])
            toolbar.translatesAutoresizingMaskIntoConstraints = false
            options.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(toolbar)
            style.addSubview(options)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                toolbar.centerYAnchor.constraint(equalTo: card.centerYAnchor), toolbar.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: 32),
                options.centerXAnchor.constraint(equalTo: style.centerXAnchor), options.centerYAnchor.constraint(equalTo: style.centerYAnchor),
                options.heightAnchor.constraint(equalToConstant: 22)
            ])
            canvas.onSelectionChange = { [weak self] in self?.positionTools() }
        } else {
        for view in [canvas, toolbar, options, feedback, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            canvas.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -10),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: options.topAnchor, constant: -8),
            options.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            options.heightAnchor.constraint(equalToConstant: 22),
            feedback.leadingAnchor.constraint(equalTo: options.trailingAnchor, constant: 12),
            feedback.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            feedback.centerYAnchor.constraint(equalTo: options.centerYAnchor),
            options.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -4),
            toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        }
        canvas.onChange = { [weak self] in self?.updateHistory() }
        updateHistory()
        updateToolAppearance()
        refreshStyleControls()
        if let captureScreen {
            panel.setFrame(captureScreen.frame, display: true)
            root.layoutSubtreeIfNeeded()
            positionTools()
        } else {
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        }
        panel.initialFirstResponder = canvas
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = ScreenshotToolButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.contentTintColor = .labelColor
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    private func floatingCard(size: NSSize) -> NSVisualEffectView {
        let card = ScreenshotToolbarView(frame: NSRect(origin: .zero, size: size))
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.appearance = NSAppearance(named: .darkAqua)
        return card
    }
    private func updateToolAppearance() {
        let buttons = toolButtons + [selectionButton].compactMap { $0 }
        for button in buttons {
            button.contentTintColor = button.state == .on ? .controlAccentColor : .labelColor
            (button as? ScreenshotToolButton)?.refreshBackground()
        }
    }
    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    private func positionTools() {
        guard let card = floatingControls, let root = window?.contentView else { return }
        guard let rect = canvas.selectionViewRect, rect.width >= 2, rect.height >= 2 else {
            card.isHidden = true
            floatingStyle?.isHidden = true
            feedback.isHidden = true
            selectionHint?.isHidden = false
            canvas.cursorExclusions = []
            window?.invalidateCursorRects(for: canvas)
            return
        }
        card.isHidden = false
        feedback.isHidden = false
        selectionHint?.isHidden = true
        let showStyle = !canvas.selectionMode
        floatingStyle?.isHidden = !showStyle
        if let style = floatingStyle {
            style.setFrameSize(NSSize(width: max(160, options.fittingSize.width + 24), height: 36))
        }
        let extraHeight: CGFloat = showStyle ? 42 : 0
        let x = min(root.bounds.maxX - card.frame.width - 10, max(10, rect.maxX - card.frame.width))
        let below = rect.minY - card.frame.height - 8
        let above = rect.maxY + 8
        let fitsBelow = below - extraHeight >= 10
        var y = fitsBelow ? below : above
        if y + card.frame.height + extraHeight > root.bounds.maxY - 10 { y = 10 + extraHeight }
        card.setFrameOrigin(NSPoint(x: x, y: y))
        if let style = floatingStyle {
            let styleY = fitsBelow || y < rect.minY ? y - style.frame.height - 6 : y + card.frame.height + 6
            style.setFrameOrigin(NSPoint(x: x, y: styleY))
        }
        if let selection = canvas.selection {
            feedback.stringValue = "  \(Int(selection.integral.width)) × \(Int(selection.integral.height))  "
            feedback.sizeToFit()
            let labelY = rect.maxY + feedback.frame.height + 6 <= root.bounds.maxY ? rect.maxY + 6 : rect.maxY - feedback.frame.height - 6
            feedback.setFrameOrigin(NSPoint(x: min(root.bounds.maxX - feedback.frame.width - 6, max(6, rect.minX)), y: labelY))
            if feedback.frame.intersects(card.frame) {
                feedback.setFrameOrigin(NSPoint(x: feedback.frame.minX, y: max(6, rect.maxY - feedback.frame.height - 6)))
            }
            feedback.isHidden = feedback.frame.intersects(card.frame)
                || (floatingStyle.map { !$0.isHidden && feedback.frame.intersects($0.frame) } ?? false)
        }
        canvas.cursorExclusions = [card, floatingStyle].compactMap { $0 }.filter { !$0.isHidden }.map { canvas.convert($0.bounds, from: $0) }
        window?.invalidateCursorRects(for: canvas)
        window?.invalidateCursorRects(for: card)
        if let style = floatingStyle { window?.invalidateCursorRects(for: style) }
    }
    @objc private func selectRegion() {
        canvas.commitText()
        canvas.selectionMode = true
        selectionButton?.state = .on
        toolButtons.forEach { $0.state = .off }
        updateToolAppearance()
        positionTools()
        window?.makeFirstResponder(canvas)
        window?.invalidateCursorRects(for: canvas)
    }
    @objc private func cancelCapture() { close() }
    private func updateHistory() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
    }
    @objc private func changeColor(_ sender: NSButton) {
        canvas.commitText()
        selectedColor = sender.tag
        canvas.color = colors[selectedColor]
        refreshStyleControls()
        window?.makeFirstResponder(canvas)
    }
    @objc private func changeStyle() {
        canvas.commitText()
        canvas.thickness = [CGFloat(0.6), 1, 1.8][widthPicker.indexOfSelectedItem]
        canvas.textSize = [CGFloat(14), 18, 24, 32][textSizePicker.indexOfSelectedItem]
        canvas.coverEffect = coverPicker.indexOfSelectedItem == 0 ? .pixelate : .solid
        refreshStyleControls()
        positionTools()
        window?.makeFirstResponder(canvas)
    }
    private func refreshStyleControls() {
        let isText = canvas.tool == .text || canvas.tool == .number
        let isCover = canvas.tool == .cover
        palette.isHidden = isCover
        textSizePicker.isHidden = !isText
        coverPicker.isHidden = !isCover
        widthPicker.isHidden = isText || (isCover && canvas.coverEffect == .solid)
        for (index, button) in colorButtons.enumerated() {
            button.layer?.borderWidth = index == selectedColor ? 1.5 : 0
            button.layer?.borderColor = NSColor.labelColor.cgColor
        }
    }
    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotation.Tool(rawValue: sender.tag) else { return }
        canvas.commitText()
        canvas.tool = tool
        canvas.selectionMode = false
        selectionButton?.state = .off
        toolButtons.forEach { $0.state = $0 === sender ? .on : .off }
        refreshStyleControls()
        updateToolAppearance()
        positionTools()
        window?.invalidateCursorRects(for: canvas)
        window?.makeFirstResponder(canvas)
    }
    func editImage() {
        canvas.editing = true
        window?.makeKeyAndOrderFront(nil)
    }
    private func activateTool(_ tool: ScreenshotAnnotation.Tool) {
        if let button = toolButtons.first(where: { $0.tag == tool.rawValue }) { selectTool(button) }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            switch key {
            case "c": copyImage()
            case "s": saveImage()
            case "z": event.modifierFlags.contains(.shift) ? redoMark() : undoMark()
            default: return false
            }
            return true
        }
        guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return false }
        switch key {
        case "\r": copyImage()
        case "\u{1b}": close()
        case "v": selectRegion()
        case "f":
            if canvas.selectionEnabled { canvas.selection = NSRect(origin: .zero, size: canvas.image.size) }
        case "a": activateTool(.arrow)
        case "r": activateTool(.rectangle)
        case "t": activateTool(.text)
        case "x": activateTool(.cover)
        case "e": activateTool(.ellipse)
        case "l": activateTool(.line)
        case "b": activateTool(.pen)
        case "h": activateTool(.highlight)
        case "n": activateTool(.number)
        case "p": pinImage()
        case "o": recognize()
        default: return false
        }
        return true
    }
    @objc private func undoMark() { canvas.commitText(); canvas.undoAnnotation() }
    @objc private func redoMark() { canvas.redoAnnotation() }
    @objc func copyImage() {
        canvas.commitText()
        guard let data = exportPNG() else { showFailure(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: .png) { close() }
        else { showFailure() }
    }
    @objc func saveImage() {
        canvas.commitText()
        guard let window, let data = exportPNG() else { showFailure(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Tactora-" + formatter.string(from: Date()) + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.close()
            } catch { self?.feedback.stringValue = error.localizedDescription }
        }
    }
    @objc private func pinImage() {
        canvas.commitText()
        guard let image = exportImage(), let onPin else { showFailure(); return }
        onPin(image)
        close()
    }
    @objc private func recognize() {
        canvas.commitText()
        guard ToolFeature.ocr.isEnabled() else {
            feedback.stringValue = AppLanguage.english ? "Enable OCR in General settings" : "请在通用设置中开启截图识字"
            return
        }
        guard let data = canvas.pngData(), let onOCR else { showFailure(); return }
        onOCR(data)
        close()
    }
    private func exportImage() -> NSImage? {
        guard let source = canvas.renderedImage() else { return nil }
        guard let appearanceOptions else { return source }
        return appearanceOptions.render(source)
    }
    private func exportPNG() -> Data? {
        guard let image = exportImage(), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    @objc private func editAppearance() {
        canvas.commitText()
        guard let window, window.attachedSheet == nil, let image = canvas.renderedImage() else { return }
        let sheet = ScreenshotAppearanceSheet(image: image, value: appearanceOptions ?? ScreenshotAppearance())
        appearanceSheet = sheet
        sheet.onApply = { [weak self] value in self?.appearanceOptions = value }
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow) { [weak self] _ in self?.appearanceSheet = nil } }
    }
    @objc private func startSession(_ sender: NSButton) {
        canvas.commitText()
        guard onSession != nil, let captureScreen, let selection = canvas.selection, selection.width >= 64, selection.height >= 64 else {
            feedback.stringValue = "请先选择至少 64 × 64 像素的区域"
            return
        }
        let mode: ScreenshotSession.Mode = sender.tag == 1 ? .scroll : (sender.tag == 2 ? .video : .gif)
        let alert = NSAlert()
        alert.messageText = sender.toolTip ?? ""
        alert.informativeText = mode == .scroll
            ? "将捕获所选区域的实时画面。向下滚动后逐帧添加，完成后继续标注。请避开固定页眉和动态内容。现有标注仅属于当前静态截图。"
            : "录制所选区域的实时画面，包含鼠标指针，无音频。视频最长 30 分钟、最长边 1920 像素，GIF 最长 60 秒、最长边 960 像素。完成后选择保存位置。"
        let rate = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        rate.addItems(withTitles: mode == .gif ? ["8 fps", "12 fps"] : ["15 fps", "30 fps"])
        if mode != .scroll { alert.accessoryView = rate }
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let factor = self.canvas.contentScale
            let region = CGRect(x: selection.minX / factor, y: (self.canvas.image.size.height - selection.maxY) / factor,
                                width: selection.width / factor, height: selection.height / factor)
            let fps = mode == .gif ? [8, 12][rate.indexOfSelectedItem] : [15, 30][rate.indexOfSelectedItem]
            let callback = self.onSession
            self.close()
            callback?(mode, captureScreen, region, fps)
        }
    }
    private func showFailure() { feedback.stringValue = AppLanguage.english ? "Could not export image" : "无法导出图片" }
}
