import AppKit

/// Resolution-independent, monochrome family built around paired forms and an S-shaped opening.
@MainActor
enum ToolIcon {
    private static func canvas(_ rect: NSRect, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.maxY)
        (transform as NSAffineTransform).concat()
        NSAffineTransform(transform: AffineTransform(scaleByX: rect.width / 100, byY: -rect.height / 100)).concat()
        NSColor.black.setFill()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func lobe() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 30, y: 4))
        p.curve(to: NSPoint(x: 4, y: 30), controlPoint1: NSPoint(x: 13, y: 4), controlPoint2: NSPoint(x: 4, y: 13))
        p.line(to: NSPoint(x: 4, y: 65))
        p.curve(to: NSPoint(x: 16, y: 74), controlPoint1: NSPoint(x: 4, y: 76), controlPoint2: NSPoint(x: 10, y: 79))
        p.curve(to: NSPoint(x: 33, y: 67), controlPoint1: NSPoint(x: 22, y: 70), controlPoint2: NSPoint(x: 28, y: 68))
        p.curve(to: NSPoint(x: 34, y: 62), controlPoint1: NSPoint(x: 38, y: 66), controlPoint2: NSPoint(x: 38, y: 64))
        p.curve(to: NSPoint(x: 46, y: 27), controlPoint1: NSPoint(x: 16, y: 53), controlPoint2: NSPoint(x: 23, y: 27))
        p.line(to: NSPoint(x: 72, y: 27))
        p.curve(to: NSPoint(x: 72, y: 4), controlPoint1: NSPoint(x: 88, y: 27), controlPoint2: NSPoint(x: 88, y: 4))
        p.close()
        return p
    }

    private static func mark(_ rect: NSRect, color: NSColor = .black) {
        canvas(rect) {
            color.setFill()
            let first = lobe(); first.fill()
            let second = lobe()
            second.transform(using: AffineTransform(m11: -1, m12: 0, m21: 0, m22: -1, tX: 100, tY: 100))
            second.fill()
        }
    }

    private static func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private static func cup(_ rect: NSRect) {
        canvas(rect) {
            let handle = rounded(NSRect(x: 63, y: 39, width: 33, height: 39), radius: 17)
            handle.append(rounded(NSRect(x: 70, y: 49, width: 16, height: 19), radius: 8))
            handle.windingRule = .evenOdd; handle.fill()
            // The steam is deliberately shorter than in the presentation artwork.
            let steam = NSBezierPath()
            steam.move(to: NSPoint(x: 46, y: 5))
            steam.curve(to: NSPoint(x: 37, y: 24), controlPoint1: NSPoint(x: 51, y: 15), controlPoint2: NSPoint(x: 33, y: 13))
            steam.lineWidth = 7; steam.lineCapStyle = .round; NSColor.black.setStroke(); steam.stroke()
        }
        mark(NSRect(x: rect.minX, y: rect.minY, width: rect.width * 0.80, height: rect.height * 0.70))
    }

    static func appImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor(srgbRed: 0.105, green: 0.11, blue: 0.115, alpha: 1).setFill()
            rounded(NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84), radius: size * 0.19).fill()
            mark(NSRect(x: size * 0.205, y: size * 0.205, width: size * 0.59, height: size * 0.59), color: .white)
            return true
        }
    }

    private static var featureCache: [String: NSImage] = [:]
    static func featureImage(symbol: String) -> NSImage {
        if let cached = featureCache[symbol] { return cached }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let rect = NSRect(x: 1, y: 1, width: 18, height: 18)
            if symbol == "square.stack.3d.up" { mark(rect) }
            else if symbol.hasPrefix("cup.and.saucer") { cup(rect) }
            else {
                canvas(rect) {
                    switch symbol {
                    case "doc.on.clipboard":
                        let body = rounded(NSRect(x: 12, y: 16, width: 76, height: 80), radius: 18)
                        body.append(rounded(NSRect(x: 25, y: 29, width: 50, height: 54), radius: 10))
                        body.windingRule = .evenOdd; body.fill()
                        rounded(NSRect(x: 30, y: 4, width: 40, height: 28), radius: 10).fill()
                    case "photo":
                        let frame = rounded(NSRect(x: 4, y: 9, width: 92, height: 82), radius: 20)
                        frame.append(rounded(NSRect(x: 17, y: 22, width: 66, height: 56), radius: 10))
                        frame.windingRule = .evenOdd; frame.fill()
                        NSBezierPath(ovalIn: NSRect(x: 61, y: 30, width: 14, height: 14)).fill()
                        let hill = NSBezierPath(); hill.move(to: NSPoint(x: 12, y: 76))
                        hill.curve(to: NSPoint(x: 52, y: 59), controlPoint1: NSPoint(x: 28, y: 77), controlPoint2: NSPoint(x: 31, y: 40))
                        hill.curve(to: NSPoint(x: 88, y: 72), controlPoint1: NSPoint(x: 71, y: 78), controlPoint2: NSPoint(x: 73, y: 72))
                        hill.line(to: NSPoint(x: 88, y: 85)); hill.line(to: NSPoint(x: 12, y: 85)); hill.close(); hill.fill()
                    default:
                        let frame = rounded(NSRect(x: 4, y: 10, width: 92, height: 80), radius: 18)
                        frame.append(rounded(NSRect(x: 17, y: 24, width: 66, height: 52), radius: 8))
                        frame.windingRule = .evenOdd; frame.fill()
                        rounded(NSRect(x: 24, y: 31, width: 24, height: 38), radius: 7).fill()
                        rounded(NSRect(x: 55, y: 31, width: 21, height: 12), radius: 6).fill()
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        featureCache[symbol] = image
        return image
    }

    private static let idle = makeStatusImage(awake: false)
    private static let awake = makeStatusImage(awake: true)
    static func statusImage(awake: Bool) -> NSImage { awake ? self.awake : idle }
    private static func makeStatusImage(awake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: awake ? 40 : 18, height: 18), flipped: false) { _ in
            mark(NSRect(x: 1, y: 1, width: 16, height: 16))
            if awake { cup(NSRect(x: 23, y: 1, width: 16, height: 16)) }
            return true
        }
        image.isTemplate = true
        return image
    }
}
