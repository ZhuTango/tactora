import AppKit

@main struct ScreenshotPinChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let frame = NSRect(x: 120, y: 180, width: 400, height: 200)
        let panel = ScreenshotPinPanel(image: image, frame: frame)
        precondition(panel.frame == frame, "Pin must preserve source position and size")
        for original in [NSRect(x: -1700, y: 240, width: 900, height: 600),
                         NSRect(x: 250, y: 300, width: 20, height: 15)] {
            let exact = ScreenshotPinPanel(image: image, frame: original)
            precondition(exact.frame == original, "Large and tiny selections must not be resized or recentered")
            exact.close()
        }
        precondition(!panel.styleMask.contains(.titled), "Pinned image must have no title bar")
        precondition(panel.canBecomeKey && !panel.hidesOnDeactivate)
        panel.makeKeyAndOrderFront(nil)
        panel.resizePin(by: 1.5)
        precondition(panel.frame.size == NSSize(width: 600, height: 300))
        precondition(panel.frame.midX == frame.midX && panel.frame.midY == frame.midY)
        panel.adjustOpacity(by: -2)
        precondition(panel.alphaValue == 0.15)
        panel.adjustOpacity(by: 2)
        precondition(panel.alphaValue == 1)
        func key(_ characters: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
            panel.sendEvent(event)
        }
        key("z")
        precondition(panel.frame.size == frame.size)
        key("z")
        precondition(panel.frame.size == NSSize(width: 600, height: 300))
        key("s")
        precondition(panel.frame.size == NSSize(width: 120, height: 60))
        key("s")
        precondition(panel.frame.size == NSSize(width: 600, height: 300))
        precondition(panel.contentView!.menu!.items.contains { $0.title.contains("原位") || $0.title.contains("original position") })
        panel.contentView!.layoutSubtreeIfNeeded()
        let button = panel.contentView!.subviews.compactMap { $0 as? NSButton }.first!
        precondition(button.identifier?.rawValue == "screenshot.pin.close")
        precondition(button.frame.minX == 6 && panel.contentView!.bounds.maxY - button.frame.maxY == 6, "Close must stay at top left")
        button.performClick(nil)
        precondition(!panel.isVisible, "Close button must dismiss pinned image")
        panel.makeKeyAndOrderFront(nil)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        panel.sendEvent(event)
        precondition(!panel.isVisible, "Focused Escape must dismiss pinned image")
        print("PASS: borderless pinned image, top-left close button and focused Escape")
    }
}
