import AppKit
import UniformTypeIdentifiers

struct ScreenshotAnnotation {
    enum Tool: Int, CaseIterable { case arrow, rectangle, text, cover }
    let tool: Tool
    let start: NSPoint
    let end: NSPoint
    var text = ""
    var color: NSColor = .systemRed
    var thickness: CGFloat = 1
    var rect: NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

@MainActor
final class ScreenshotCanvas: NSView, NSTextFieldDelegate {
    let image: NSImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private var redoItems: [ScreenshotAnnotation] = []
    private var draft: ScreenshotAnnotation?
    var editing = true
    var color: NSColor = .systemRed
    var thickness: CGFloat = 1
    private var textEditor: NSTextField?
    private var textOrigin = NSPoint.zero
    var selectionEnabled = false
    var selectionMode = true
    var selection: NSRect? {
        didSet { needsDisplay = true; onSelectionChange?() }
    }
    var onSelectionChange: (() -> Void)?
    private var selectionDrag: (handle: Int, start: NSPoint, original: NSRect)?
    var tool = ScreenshotAnnotation.Tool.arrow
    var onChange: (() -> Void)?

    init(image: NSImage) {
        // Use pixel coordinates throughout, preserving Retina resolution on export.
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else { self.image = image }
        super.init(frame: .zero)
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
    }
    var selectionViewRect: NSRect? {
        guard let selection else { return nil }
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
    private func drawImage(includingDraft: Bool) {
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        if selectionEnabled, let selection { NSBezierPath(rect: selection).addClip() }
        let items = annotations + (includingDraft ? draft.map { [$0] } ?? [] : [])
        for item in items {
            let lineWidth = max(3, min(image.size.width, image.size.height) / 220) * item.thickness
            item.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            switch item.tool {
            case .cover:
                // Solid coverage exports opaque pixels instead of recoverable visual blur.
                NSColor.black.setFill(); item.rect.fill()
            case .rectangle:
                path.appendRect(item.rect); path.stroke()
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
                let font = NSFont.systemFont(ofSize: max(18, lineWidth * 6), weight: .semibold)
                (item.text as NSString).draw(at: item.start, withAttributes: [.font: font, .foregroundColor: item.color])
            }
        }
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
        guard editing, let point = point(for: event, clamp: false) else { return }
        commitText()
        window?.makeFirstResponder(self)
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
        if tool == .text { beginText(at: point); return }
        draft = ScreenshotAnnotation(tool: tool, start: point, end: point, color: color, thickness: thickness)
    }
    override func mouseDragged(with event: NSEvent) {
        if let drag = selectionDrag, let point = point(for: event, clamp: true) {
            selection = ScreenshotSelection.drag(handle: drag.handle, start: drag.start, point: point, original: drag.original, bounds: NSRect(origin: .zero, size: image.size))
            return
        }
        guard let draft, let point = point(for: event, clamp: true) else { return }
        self.draft = ScreenshotAnnotation(tool: draft.tool, start: draft.start, end: point, color: draft.color, thickness: draft.thickness)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if selectionDrag != nil {
            mouseDragged(with: event)
            selectionDrag = nil
            if let selection, selection.width < 2 || selection.height < 2 { self.selection = nil }
            return
        }
        guard let draft else { return }
        self.draft = nil
        if let point = point(for: event, clamp: true), hypot(point.x - draft.start.x, point.y - draft.start.y) >= 2 {
            append(ScreenshotAnnotation(tool: draft.tool, start: draft.start, end: point, color: draft.color, thickness: draft.thickness))
        }
        needsDisplay = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: selectionEnabled && selectionMode ? .crosshair : tool == .text ? .iBeam : .crosshair)
        if selectionEnabled, let rect = selectionViewRect {
            if selectionMode { addCursorRect(rect.insetBy(dx: 8, dy: 8), cursor: .openHand) }
            addCursorRect(NSRect(x: rect.minX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: rect.maxX - 5, y: rect.minY, width: 10, height: rect.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: rect.minX, y: rect.minY - 5, width: rect.width, height: 10), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: rect.minX, y: rect.maxY - 5, width: rect.width, height: 10), cursor: .resizeUpDown)
        }
    }
    func beginText(at point: NSPoint) {
        commitText()
        textOrigin = point
        let field = NSTextField()
        field.placeholderString = AppLanguage.english ? "Type text" : "输入文字"
        let lineWidth = max(3, min(image.size.width, image.size.height) / 220) * thickness
        field.font = .systemFont(ofSize: max(18, lineWidth * 6) * imageRect.width / image.size.width, weight: .semibold)
        field.textColor = color
        field.backgroundColor = .textBackgroundColor
        field.isBezeled = true
        field.focusRingType = .exterior
        field.delegate = self
        field.target = self
        field.action = #selector(finishText)
        field.setAccessibilityLabel(AppLanguage.english ? "Annotation text" : "标注文字")
        textEditor = field
        addSubview(field)
        layoutTextEditor()
        window?.makeFirstResponder(field)
    }
    override func layout() {
        super.layout()
        layoutTextEditor()
    }
    private func layoutTextEditor() {
        guard let field = textEditor else { return }
        let rect = imageRect
        let scale = rect.width / image.size.width
        let width = min(240, rect.width)
        let x = min(rect.maxX - width, rect.minX + textOrigin.x * scale)
        let y = min(rect.maxY - 28, rect.minY + textOrigin.y * scale)
        field.frame = NSRect(x: x, y: max(rect.minY, y), width: width, height: 28)
    }
    @objc private func finishText() { commitText() }
    func commitText() {
        guard let field = textEditor else { return }
        let value = field.stringValue
        textEditor = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(ScreenshotAnnotation(tool: .text, start: textOrigin, end: textOrigin, text: value, color: color, thickness: thickness))
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        textEditor?.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        return true
    }
    func append(_ annotation: ScreenshotAnnotation) {
        annotations.append(annotation); redoItems.removeAll(); needsDisplay = true; onChange?()
    }
    func undoAnnotation() {
        guard let item = annotations.popLast() else { return }
        redoItems.append(item); needsDisplay = true; onChange?()
    }
    func redoAnnotation() {
        guard let item = redoItems.popLast() else { return }
        annotations.append(item); needsDisplay = true; onChange?()
    }
    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !redoItems.isEmpty }
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
    private let feedback = NSTextField(labelWithString: "")
    private var undoButton: NSButton!
    private var toolButtons: [NSButton] = []
    private let colorPicker = NSPopUpButton()
    private let widthPicker = NSPopUpButton()
    private var floatingControls: NSView?
    private var floatingStyle: NSView?
    private var selectionButton: NSButton?
    private var selectionHint: NSTextField?
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemBlue, .systemGreen, .white, .black]

    init(image: NSImage, captureScreen: NSScreen? = nil, selectWhole: Bool = false) {
        canvas = ScreenshotCanvas(image: image)
        canvas.selectionEnabled = captureScreen != nil
        if selectWhole { canvas.selection = NSRect(origin: .zero, size: canvas.image.size) }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let available = NSSize(width: min(1100, area.width - 48), height: min(800, area.height - 80))
        let scale = min(1, min((available.width - 24) / image.size.width, (available.height - 100) / image.size.height))
        let size = NSSize(width: max(600, image.size.width * scale + 24), height: max(220, image.size.height * scale + 100))
        let panel = ScreenshotPanel(contentRect: captureScreen?.frame ?? NSRect(origin: .zero, size: size), styleMask: captureScreen == nil ? [.titled, .closable, .resizable, .utilityWindow] : [.borderless], backing: .buffered, defer: false)
        panel.title = AppLanguage.english ? "Screenshot" : "截图"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = captureScreen == nil ? .floating : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.minSize = NSSize(width: 600, height: 220)
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
        let definitions = [
            ("arrow.up.right", AppLanguage.english ? "Arrow · A" : "箭头 · A"),
            ("rectangle", AppLanguage.english ? "Rectangle · R" : "矩形 · R"),
            ("textformat", AppLanguage.english ? "Text · T" : "文字 · T"),
            ("rectangle.fill", AppLanguage.english ? "Cover · X" : "遮挡 · X")
        ]
        for (index, definition) in definitions.enumerated() {
            let button = iconButton(definition.0, label: definition.1, action: #selector(selectTool(_:)))
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("screenshot.tool.\(index)")
            button.setButtonType(.toggle)
            toolbar.addArrangedSubview(button)
            toolButtons.append(button)
        }
        toolButtons[0].state = captureScreen == nil ? .on : .off
        toolbar.addArrangedSubview(separator())
        undoButton = iconButton("arrow.uturn.backward", label: AppLanguage.english ? "Undo · ⌘Z" : "撤销 · ⌘Z", action: #selector(undoMark))
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(separator())
        toolbar.addArrangedSubview(iconButton("pin", label: AppLanguage.english ? "Pin · P" : "贴图 · P", action: #selector(pinImage)))
        toolbar.addArrangedSubview(iconButton("ellipsis", label: AppLanguage.english ? "More actions" : "更多操作", action: #selector(showMore(_:))))
        toolbar.addArrangedSubview(iconButton("xmark", label: AppLanguage.english ? "Cancel · Esc" : "取消 · Esc", action: #selector(cancelCapture)))
        let copy = iconButton("checkmark", label: AppLanguage.english ? "Copy and close · Enter" : "复制并关闭 · Enter", action: #selector(copyImage))
        copy.bezelStyle = .rounded
        copy.contentTintColor = .controlAccentColor
        copy.toolTip = AppLanguage.english ? "Copy and close · Enter / ⌘C" : "复制并关闭 · Enter / ⌘C"
        toolbar.addArrangedSubview(copy)
        colorPicker.addItems(withTitles: AppLanguage.english ? ["Red", "Orange", "Blue", "Green", "White", "Black"] : ["红色", "橙色", "蓝色", "绿色", "白色", "黑色"])
        colorPicker.target = self
        colorPicker.action = #selector(changeStyle)
        colorPicker.setAccessibilityLabel(AppLanguage.english ? "Annotation color" : "标注颜色")
        widthPicker.addItems(withTitles: AppLanguage.english ? ["Thin", "Medium", "Thick"] : ["细", "中", "粗"])
        widthPicker.selectItem(at: 1)
        widthPicker.target = self
        widthPicker.action = #selector(changeStyle)
        widthPicker.setAccessibilityLabel(AppLanguage.english ? "Stroke width" : "线条粗细")
        colorPicker.controlSize = .small
        widthPicker.controlSize = .small
        let options = NSStackView(views: [colorPicker, widthPicker])
        options.spacing = 8
        feedback.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        feedback.stringValue = "\(Int(canvas.image.size.width)) × \(Int(canvas.image.size.height)) px"
        let divider = NSBox()
        divider.boxType = .separator
        if captureScreen != nil {
            let card = floatingCard(size: NSSize(width: 384, height: 44))
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
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
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
        let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
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
            button.layer?.backgroundColor = button.state == .on ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        }
    }
    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let save = NSMenuItem(title: AppLanguage.english ? "Save…" : "保存…", action: #selector(saveImage), keyEquivalent: "s")
        let ocr = NSMenuItem(title: AppLanguage.english ? "Recognize text" : "识别文字", action: #selector(recognize), keyEquivalent: "")
        let redo = NSMenuItem(title: AppLanguage.english ? "Redo" : "重做", action: #selector(redoMark), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.isEnabled = canvas.canRedo
        for item in [save, ocr, redo] { item.target = self; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
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
            return
        }
        card.isHidden = false
        feedback.isHidden = false
        selectionHint?.isHidden = true
        let showStyle = !canvas.selectionMode && canvas.tool != .cover
        floatingStyle?.isHidden = !showStyle
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
        window?.invalidateCursorRects(for: canvas)
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
    }
    @objc private func changeStyle() {
        canvas.commitText()
        canvas.color = colors[colorPicker.indexOfSelectedItem]
        canvas.thickness = [CGFloat(0.6), 1, 1.8][widthPicker.indexOfSelectedItem]
        window?.makeFirstResponder(canvas)
    }
    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotation.Tool(rawValue: sender.tag) else { return }
        canvas.commitText()
        canvas.tool = tool
        canvas.selectionMode = false
        selectionButton?.state = .off
        toolButtons.forEach { $0.state = $0 === sender ? .on : .off }
        colorPicker.isEnabled = tool != .cover
        widthPicker.isEnabled = tool != .cover
        updateToolAppearance()
        positionTools()
        window?.invalidateCursorRects(for: canvas)
        window?.makeFirstResponder(canvas)
    }
    func editImage() {
        canvas.editing = true
        window?.makeKeyAndOrderFront(nil)
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
        case "a": selectTool(toolButtons[0])
        case "r": selectTool(toolButtons[1])
        case "t": selectTool(toolButtons[2])
        case "x": selectTool(toolButtons[3])
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
        guard let data = canvas.pngData() else { showFailure(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: .png) { close() }
        else { showFailure() }
    }
    @objc func saveImage() {
        canvas.commitText()
        guard let window, let data = canvas.pngData() else { showFailure(); return }
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
        guard let image = canvas.renderedImage(), let onPin else { showFailure(); return }
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
    private func showFailure() { feedback.stringValue = AppLanguage.english ? "Could not export image" : "无法导出图片" }
}
