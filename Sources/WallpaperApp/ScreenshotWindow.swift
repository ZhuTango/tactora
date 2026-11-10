import AppKit
import UniformTypeIdentifiers

struct ScreenshotAnnotation {
    enum Tool: Int, CaseIterable { case arrow, rectangle, text, cover }
    let tool: Tool
    let start: NSPoint
    let end: NSPoint
    var text = ""
    var rect: NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

@MainActor
final class ScreenshotCanvas: NSView {
    let image: NSImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private var redoItems: [ScreenshotAnnotation] = []
    private var draft: ScreenshotAnnotation?
    var editing = false
    var tool = ScreenshotAnnotation.Tool.arrow
    var onChange: (() -> Void)?
    var onText: ((NSPoint) -> Void)?
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
    }
    private func drawImage(includingDraft: Bool) {
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        let items = annotations + (includingDraft ? draft.map { [$0] } ?? [] : [])
        let lineWidth = max(3, min(image.size.width, image.size.height) / 220)
        for item in items {
            NSColor.systemRed.setStroke()
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
                (item.text as NSString).draw(at: item.start, withAttributes: [.font: font, .foregroundColor: NSColor.systemRed])
            }
        }
    }
    func renderedImage() -> NSImage? {
        let size = image.size
        guard size.width >= 1, size.height >= 1,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
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
        if tool == .text { onText?(point); return }
        draft = ScreenshotAnnotation(tool: tool, start: point, end: point)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let draft, let point = point(for: event, clamp: true) else { return }
        self.draft = ScreenshotAnnotation(tool: draft.tool, start: draft.start, end: point)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let draft else { return }
        self.draft = nil
        if let point = point(for: event, clamp: true), hypot(point.x - draft.start.x, point.y - draft.start.y) >= 2 {
            append(ScreenshotAnnotation(tool: draft.tool, start: draft.start, end: point))
        }
        needsDisplay = true
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
final class ScreenshotWindow: NSWindowController, NSWindowDelegate {
    let canvas: ScreenshotCanvas
    var onClose: (() -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onOCR: ((Data) -> Void)?
    private let tools = NSStackView()
    private let feedback = NSTextField(labelWithString: "")
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var toolButtons: [NSButton] = []
    private var toolbarHeight: NSLayoutConstraint!
    init(image: NSImage) {
        canvas = ScreenshotCanvas(image: image)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 290), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = AppLanguage.english ? "Screenshot" : "截图"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.minSize = NSSize(width: 400, height: 250)
        super.init(window: panel)
        panel.delegate = self
        let root = NSView()
        panel.contentView = root
        let definitions: [(String, String)] = [("arrow.up.right", AppLanguage.english ? "Arrow" : "箭头"), ("rectangle", AppLanguage.english ? "Rectangle" : "矩形"), ("textformat", AppLanguage.english ? "Text" : "文字"), ("rectangle.fill", AppLanguage.english ? "Cover" : "遮挡")]
        for (index, definition) in definitions.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: definition.0, accessibilityDescription: definition.1)!, target: self, action: #selector(selectTool(_:)))
            button.tag = index
            button.setButtonType(.toggle)
            button.toolTip = definition.1
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            tools.addArrangedSubview(button); toolButtons.append(button)
        }
        toolButtons[0].state = .on
        undoButton = NSButton(title: "↶", target: self, action: #selector(undoMark))
        undoButton.toolTip = AppLanguage.english ? "Undo" : "撤销"
        undoButton.setAccessibilityLabel(undoButton.toolTip!)
        undoButton.keyEquivalent = "z"
        redoButton = NSButton(title: "↷", target: self, action: #selector(redoMark))
        redoButton.toolTip = AppLanguage.english ? "Redo" : "重做"
        redoButton.setAccessibilityLabel(redoButton.toolTip!)
        redoButton.keyEquivalent = "z"; redoButton.keyEquivalentModifierMask = [.command, .shift]
        tools.addArrangedSubview(undoButton); tools.addArrangedSubview(redoButton)
        tools.spacing = 8; tools.isHidden = true
        let copy = NSButton(title: AppLanguage.english ? "Copy" : "复制", target: self, action: #selector(copyImage))
        copy.keyEquivalent = "c"
        let save = NSButton(title: AppLanguage.english ? "Save…" : "保存…", target: self, action: #selector(saveImage))
        save.keyEquivalent = "s"
        let edit = NSButton(title: AppLanguage.english ? "Annotate" : "标注", target: self, action: #selector(editImage))
        let pin = NSButton(title: AppLanguage.english ? "Pin" : "贴图", target: self, action: #selector(pinImage))
        let ocr = NSButton(title: AppLanguage.english ? "OCR" : "识字", target: self, action: #selector(recognize))
        let actions = NSStackView(views: [copy, save, edit, pin, ocr])
        actions.spacing = 8
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        for view in [canvas, tools, actions, feedback] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        toolbarHeight = tools.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), tools.centerXAnchor.constraint(equalTo: root.centerXAnchor), toolbarHeight,
            canvas.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 8), canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), canvas.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.centerXAnchor.constraint(equalTo: root.centerXAnchor), actions.bottomAnchor.constraint(equalTo: feedback.topAnchor, constant: -6),
            feedback.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), feedback.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            feedback.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), feedback.heightAnchor.constraint(equalToConstant: 16)
        ])
        canvas.onChange = { [weak self] in self?.updateHistory() }
        canvas.onText = { [weak self] point in self?.addText(at: point) }
        updateHistory()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.minY + 330))
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func windowWillClose(_ notification: Notification) { onClose?() }
    private func updateHistory() { undoButton.isEnabled = canvas.canUndo; redoButton.isEnabled = canvas.canRedo }
    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotation.Tool(rawValue: sender.tag) else { return }
        canvas.tool = tool
        toolButtons.forEach { $0.state = $0 === sender ? .on : .off }
    }
    @objc func editImage() {
        guard let window else { return }
        canvas.editing = true; tools.isHidden = false; toolbarHeight.constant = 32
        let area = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let width = min(960, area.width - 40), height = min(720, area.height - 40)
        window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height), display: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func undoMark() { canvas.undoAnnotation() }
    @objc private func redoMark() { canvas.redoAnnotation() }
    private func addText(at point: NSPoint) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = AppLanguage.english ? "Add text" : "添加文字"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        field.setAccessibilityLabel(alert.messageText)
        alert.accessoryView = field
        alert.addButton(withTitle: AppLanguage.english ? "Add" : "添加")
        alert.addButton(withTitle: AppLanguage.english ? "Cancel" : "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            self?.canvas.append(ScreenshotAnnotation(tool: .text, start: point, end: point, text: field.stringValue))
        }
    }
    @objc func copyImage() {
        guard let data = canvas.pngData() else { showFailure(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: .png) { feedback.stringValue = AppLanguage.english ? "Copied" : "已复制" }
        else { showFailure() }
    }
    @objc func saveImage() {
        guard let window, let data = canvas.pngData() else { showFailure(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Tactora-" + formatter.string(from: Date()) + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.feedback.stringValue = AppLanguage.english ? "Saved" : "已保存"
            } catch { self?.feedback.stringValue = error.localizedDescription }
        }
    }
    @objc private func pinImage() {
        guard let image = canvas.renderedImage() else { showFailure(); return }
        onPin?(image)
    }
    @objc private func recognize() {
        guard ToolFeature.ocr.isEnabled() else {
            feedback.stringValue = AppLanguage.english ? "Enable OCR in General settings" : "请在通用设置中开启截图识字"; return
        }
        guard let data = canvas.pngData() else { showFailure(); return }
        onOCR?(data)
    }
    private func showFailure() { feedback.stringValue = AppLanguage.english ? "Could not export image" : "无法导出图片" }
}
