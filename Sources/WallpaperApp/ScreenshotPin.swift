import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotPinPanel: NSPanel {
    private let pinnedImage: NSImage
    private let originalFrame: NSRect
    private var previousSize: NSSize?
    private var thumbnailSize: NSSize?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(image: NSImage, frame: NSRect) {
        pinnedImage = image
        originalFrame = frame
        let size = frame.size
        let closeSize = min(24, size.width, size.height)
        let insetX = min(6, (size.width - closeSize) / 2)
        let insetY = min(6, (size.height - closeSize) / 2)
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = AppLanguage.english ? "Pinned Screenshot" : "贴图"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentAspectRatio = size
        minSize = NSSize(width: closeSize + insetX * 2, height: closeSize + insetY * 2)

        let view = ScreenshotPinImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(title)
        contentView = view
        view.toolTip = AppLanguage.english ? "Scroll to zoom · ⌘Scroll opacity · Z original size · S thumbnail · Double-click to close" : "滚轮缩放 · ⌘滚轮透明度 · Z 原尺寸 · S 缩略图 · 双击关闭"
        let menu = NSMenu()
        for (title, action, key) in [
            (AppLanguage.english ? "Copy" : "复制", #selector(copyPin), "c"),
            (AppLanguage.english ? "Save…" : "保存…", #selector(savePin), "s"),
            (AppLanguage.english ? "Restore original position and size" : "恢复原位和原尺寸", #selector(restoreOriginal), ""),
            (AppLanguage.english ? "Restore opacity" : "恢复不透明", #selector(restoreOpacity), ""),
            (AppLanguage.english ? "Close" : "关闭", #selector(closePin), "")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        view.menu = menu

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(closePin))
        close.bezelStyle = .circular
        close.imagePosition = .imageOnly
        close.toolTip = AppLanguage.english ? "Close · Esc" : "关闭 · Esc"
        close.setAccessibilityLabel(close.toolTip)
        close.identifier = NSUserInterfaceItemIdentifier("screenshot.pin.close")
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insetX),
            close.topAnchor.constraint(equalTo: view.topAnchor, constant: insetY),
            close.widthAnchor.constraint(equalToConstant: closeSize),
            close.heightAnchor.constraint(equalToConstant: closeSize)
        ])
    }

    func resizePin(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        let ratio = min(4, max(0.1, frame.width / originalFrame.width * factor))
        setDisplaySize(NSSize(width: originalFrame.width * ratio, height: originalFrame.height * ratio))
    }
    private func setDisplaySize(_ size: NSSize) {
        let scale = max(minSize.width / max(1, size.width), minSize.height / max(1, size.height), 1)
        let size = NSSize(width: size.width * scale, height: size.height * scale)
        let rect = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        setFrame(rect, display: true)
    }
    func adjustOpacity(by delta: CGFloat) { alphaValue = min(1, max(0.15, alphaValue + delta)) }
    @objc private func restoreOriginal() {
        previousSize = nil; thumbnailSize = nil
        setFrame(originalFrame, display: true)
    }
    @objc private func restoreOpacity() { alphaValue = 1 }
    private func toggleOriginalSize() {
        if let size = previousSize { previousSize = nil; setDisplaySize(size) }
        else { previousSize = frame.size; setDisplaySize(originalFrame.size) }
    }
    private func toggleThumbnail() {
        if let size = thumbnailSize { thumbnailSize = nil; setDisplaySize(size) }
        else {
            thumbnailSize = frame.size
            let scale = min(1, 120 / max(frame.width, frame.height))
            setDisplaySize(NSSize(width: frame.width * scale, height: frame.height * scale))
        }
    }
    private func pngData() -> Data? {
        guard let cg = pinnedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    @objc private func copyPin() {
        guard let data = pngData() else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setData(data, forType: .png) { NSSound.beep() }
    }
    @objc private func savePin() {
        guard attachedSheet == nil, let data = pngData() else { return }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.png]
        picker.nameFieldStringValue = "Tactora-Pin.png"
        picker.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { if let self { NSAlert(error: error).beginSheetModal(for: self) } }
        }
    }
    @objc private func closePin() { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    private func handleKey(_ event: NSEvent) -> Bool {
        if attachedSheet != nil { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            if key == "c" { copyPin(); return true }
            if key == "s" { savePin(); return true }
            return false
        }
        guard event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }
        switch key {
        case "z": toggleOriginalSize()
        case "s": toggleThumbnail()
        case "+", "=": resizePin(by: 1.1)
        case "-": resizePin(by: 1 / 1.1)
        case "\u{1b}": close()
        default: return false
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

}

@MainActor
private final class ScreenshotPinImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 { window?.close() }
        else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard let panel = window as? ScreenshotPinPanel, event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.002 : 0.03)
        if event.modifierFlags.contains(.command) { panel.adjustOpacity(by: delta) }
        else { panel.resizePin(by: exp(delta)) }
    }
    override func magnify(with event: NSEvent) {
        (window as? ScreenshotPinPanel)?.resizePin(by: 1 + event.magnification)
    }
}
