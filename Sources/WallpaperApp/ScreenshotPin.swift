import AppKit

@MainActor
final class ScreenshotPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(image: NSImage, screenFrame: NSRect) {
        let scale = min(1, min(500 / image.size.width, 400 / image.size.height))
        let size = NSSize(width: max(120, image.size.width * scale), height: max(80, image.size.height * scale))
        let frame = NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = AppLanguage.english ? "Pinned Screenshot" : "贴图"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 120, height: 80)

        let view = ScreenshotPinImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(title)
        contentView = view

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
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            close.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @objc private func closePin() { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class ScreenshotPinImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.performDrag(with: event)
    }
}
