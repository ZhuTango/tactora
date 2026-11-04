import AppKit

/// One status item, with independently accessible controls inside a shared outline.
@MainActor
final class StatusGroupView: NSView {
    let mainButton = StatusGroupButton()
    let fanButton = StatusGroupButton()
    let calendarButton = StatusGroupButton()
    var onWidthChange: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("方寸 Tactora")
        for button in [mainButton, fanButton, calendarButton] { addSubview(button) }
        fanButton.isHidden = true
        calendarButton.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshLayout() {
        let width: CGFloat = 8 + 40 + (fanButton.isHidden ? 0 : 40) + (calendarButton.isHidden ? 0 : 28)
        onWidthChange?(width)
        setFrameSize(NSSize(width: width, height: frame.height))
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for (button, width) in [(mainButton, CGFloat(40)), (fanButton, CGFloat(40)), (calendarButton, CGFloat(28))] where !button.isHidden {
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.35).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class StatusGroupButton: NSButton {
    private var hovered = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        contentTintColor = .labelColor
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || cell?.isHighlighted == true {
            NSColor.labelColor.withAlphaComponent(cell?.isHighlighted == true ? 0.18 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}
