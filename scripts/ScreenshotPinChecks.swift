import AppKit

@main struct ScreenshotPinChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let frame = NSScreen.main!.visibleFrame
        let panel = ScreenshotPinPanel(image: image, screenFrame: frame)
        precondition(!panel.styleMask.contains(.titled), "Pinned image must have no title bar")
        precondition(panel.canBecomeKey && !panel.hidesOnDeactivate)
        panel.makeKeyAndOrderFront(nil)
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
