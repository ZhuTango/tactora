import AppKit

/// Shared geometric mark for the app bundle and the menu bar.
@MainActor
enum ToolIcon {
    private static func mark(in rect: NSRect, primary: NSColor, accent: NSColor) {
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                   width: w * rect.width, height: h * rect.height)
        }
        primary.setFill()
        NSBezierPath(roundedRect: box(0, 0, 0.32, 1), xRadius: rect.width * 0.1, yRadius: rect.height * 0.1).fill()
        NSBezierPath(roundedRect: box(0.44, 0, 0.56, 0.32), xRadius: rect.width * 0.1, yRadius: rect.height * 0.1).fill()
        // A compact diamond adds a distinct silhouette even at menu-bar scale.
        accent.setFill()
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: rect.minX + rect.width * 0.72, y: rect.maxY))
        diamond.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
        diamond.line(to: NSPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.44))
        diamond.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.72))
        diamond.close(); diamond.fill()
    }

    static func appImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let tile = NSBezierPath(roundedRect: NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84),
                                    xRadius: size * 0.19, yRadius: size * 0.19)
            NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.43, blue: 0.98, alpha: 1),
                       ending: NSColor(srgbRed: 0.18, green: 0.18, blue: 0.62, alpha: 1))!.draw(in: tile, angle: -60)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            tile.lineWidth = max(0.5, size * 0.002); tile.stroke()
            mark(in: NSRect(x: size * 0.27, y: size * 0.27, width: size * 0.46, height: size * 0.46),
                 primary: NSColor(srgbRed: 0.96, green: 0.98, blue: 1, alpha: 1),
                 accent: NSColor(srgbRed: 1, green: 0.76, blue: 0.32, alpha: 1))
            return true
        }
    }

    private static let idle = makeStatusImage(awake: false)
    private static let awake = makeStatusImage(awake: true)
    static func statusImage(awake: Bool) -> NSImage { awake ? self.awake : idle }

    private static func makeStatusImage(awake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: awake ? 40 : 18, height: 18), flipped: false) { _ in
            mark(in: NSRect(x: 1, y: 1, width: 16, height: 16), primary: .black, accent: .black)
            if awake {
                NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))?
                    .draw(in: NSRect(x: 23, y: 1, width: 16, height: 16))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
