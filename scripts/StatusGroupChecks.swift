import AppKit

@MainActor
final class GroupActions: NSObject {
    var clicks: [Int] = []
    @objc func clicked(_ sender: NSButton) { clicks.append(sender.tag) }
}

@MainActor
final class GroupPreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@main
struct StatusGroupChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let actions = GroupActions()
        let group = StatusGroupView(frame: NSRect(x: 0, y: 0, width: 116, height: 24))
        let window = NSWindow(contentRect: group.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let background = GroupPreviewBackground(frame: group.frame)
        window.contentView = background
        background.addSubview(group)
        group.mainButton.image = ToolIcon.statusImage(awake: true)
        group.fanButton.image = ToolIcon.fanReadingsImage("54° 2146")
        group.calendarButton.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")
        for (tag, button) in [group.mainButton, group.fanButton, group.calendarButton].enumerated() {
            button.tag = tag
            button.target = actions
            button.action = #selector(GroupActions.clicked(_:))
        }
        for height: CGFloat in [22, 24, 32] {
            for fans in [false, true] {
                for calendar in [false, true] {
                    group.setFrameSize(NSSize(width: 116, height: height))
                    group.fanButton.isHidden = !fans
                    group.calendarButton.isHidden = !calendar
                    group.refreshLayout()
                    precondition(group.frame.width == 48 + (fans ? 40 : 0) + (calendar ? 28 : 0))
                    let visible = [group.mainButton, group.fanButton, group.calendarButton].filter { !$0.isHidden }
                    for button in visible {
                        precondition(group.bounds.contains(button.frame))
                        precondition(group.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
                        button.performClick(nil)
                        precondition(actions.clicks.last == button.tag)
                    }
                    for (left, right) in zip(visible, visible.dropFirst()) {
                        precondition(left.frame.maxX <= right.frame.minX)
                    }
                }
            }
        }
        group.setFrameSize(NSSize(width: 116, height: 24))
        group.refreshLayout()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            background.needsDisplay = true
            let bitmap = background.bitmapImageRepForCachingDisplay(in: background.bounds)!
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/status-group-\(name.rawValue).png"))
            let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 464, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
            (name == .aqua ? NSColor.white : NSColor.black).setFill()
            NSRect(x: 0, y: 0, width: 464, height: 96).fill()
            bitmap.draw(in: NSRect(x: 0, y: 0, width: 464, height: 96))
            NSGraphicsContext.restoreGraphicsState()
            try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/status-group-preview-\(name.rawValue).png"))
        }
        print("PASS: grouped widths, hit targets, independent actions and light/dark rendering")
    }
}
