import AppKit

@MainActor
final class ScreenshotPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(image: NSImage, frame: NSRect) {
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
        minSize = NSSize(width: closeSize + insetX * 2, height: closeSize + insetY * 2)

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
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insetX),
            close.topAnchor.constraint(equalTo: view.topAnchor, constant: insetY),
            close.widthAnchor.constraint(equalToConstant: closeSize),
            close.heightAnchor.constraint(equalToConstant: closeSize)
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
