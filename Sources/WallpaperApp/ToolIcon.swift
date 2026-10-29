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

    /// Normalized closed contours: move, line, and cubic curve coordinates.
    private static func contour(_ segments: [[CGFloat]]) -> NSBezierPath {
        let path = NSBezierPath()
        for s in segments {
            switch s[0] {
            case 0: path.move(to: NSPoint(x: s[1], y: s[2]))
            case 1: path.line(to: NSPoint(x: s[1], y: s[2]))
            default: path.curve(to: NSPoint(x: s[5], y: s[6]),
                                controlPoint1: NSPoint(x: s[1], y: s[2]),
                                controlPoint2: NSPoint(x: s[3], y: s[4]))
            }
        }
        path.close()
        return path
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
            if symbol == "square.stack.3d.up" {
                canvas(rect) {
                    let upper = contour([
                        [0, 30, 8], [2, 8, 8, 4, 20, 4, 36], [1, 4, 55],
                        [2, 4, 64, 12, 68, 26, 68], [1, 41, 68],
                        [2, 51, 68, 51, 53, 41, 53], [1, 34, 53],
                        [2, 18, 53, 18, 26, 37, 26], [1, 53, 26],
                        [2, 67, 26, 67, 8, 53, 8]
                    ])
                    upper.fill()
                    let lower = upper.copy() as! NSBezierPath
                    lower.transform(using: AffineTransform(m11: -1, m12: 0, m21: 0, m22: -1, tX: 100, tY: 100))
                    lower.fill()
                }
            }
            else if symbol.hasPrefix("cup.and.saucer") { cup(rect) }
            else {
                canvas(rect) {
                    switch symbol {
                    case "doc.on.clipboard":
                        // Open shoulders and the asymmetric page corner follow the approved artwork.
                        contour([
                            [0, 27, 17], [2, 12, 17, 7, 25, 7, 39], [1, 7, 84],
                            [2, 7, 96, 15, 99, 28, 99], [1, 76, 99],
                            [2, 90, 99, 93, 90, 93, 78], [1, 93, 36],
                            [2, 93, 22, 87, 17, 76, 17], [1, 76, 29],
                            [2, 82, 31, 82, 35, 82, 41], [1, 82, 49],
                            [2, 82, 59, 73, 62, 66, 62], [1, 62, 62],
                            [2, 56, 62, 58, 72, 58, 77],
                            [2, 58, 85, 52, 88, 45, 88], [1, 30, 88],
                            [2, 21, 88, 20, 82, 20, 75], [1, 20, 45],
                            [2, 20, 38, 24, 35, 29, 34]
                        ]).fill()
                        contour([
                            [0, 42, 4], [2, 36, 4, 35, 8, 35, 13],
                            [2, 24, 16, 27, 30, 36, 30], [1, 64, 30],
                            [2, 74, 30, 76, 16, 65, 13],
                            [2, 65, 7, 61, 4, 56, 4]
                        ]).fill()
                    case "photo":
                        contour([
                            [0, 23, 9], [2, 9, 9, 4, 19, 4, 32], [1, 4, 60],
                            [2, 11, 57, 16, 52, 16, 44], [1, 16, 32],
                            [2, 16, 24, 22, 21, 29, 21], [1, 72, 21],
                            [2, 81, 21, 84, 26, 84, 34], [1, 84, 57],
                            [2, 84, 72, 65, 66, 53, 55],
                            [2, 35, 37, 24, 62, 4, 68], [1, 4, 75],
                            [2, 4, 89, 13, 91, 25, 91], [1, 76, 91],
                            [2, 91, 91, 96, 84, 96, 72], [1, 96, 31],
                            [2, 96, 16, 90, 9, 76, 9]
                        ]).fill()
                        NSBezierPath(ovalIn: NSRect(x: 57, y: 30, width: 17, height: 17)).fill()
                    default:
                        let frame = rounded(NSRect(x: 4, y: 10, width: 92, height: 80), radius: 17)
                        frame.append(contour([
                            [0, 25, 24], [2, 18, 24, 16, 29, 16, 35], [1, 16, 66],
                            [2, 16, 75, 20, 78, 28, 78], [1, 52, 78],
                            [2, 60, 78, 61, 73, 61, 66], [1, 61, 49],
                            [2, 61, 42, 64, 39, 71, 39], [1, 77, 39],
                            [2, 88, 39, 88, 24, 77, 24]
                        ]))
                        frame.windingRule = .evenOdd; frame.fill()
                        rounded(NSRect(x: 25, y: 33, width: 28, height: 37), radius: 8).fill()
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
            if awake {
                // Menu-bar optical variant: no floating steam at this scale.
                // Align the paired body with the main mark instead of its baseline.
                NSColor.black.setFill()
                let handle = rounded(NSRect(x: 33, y: 5.5, width: 6, height: 7), radius: 3)
                handle.append(rounded(NSRect(x: 34, y: 7, width: 3.5, height: 4), radius: 1.75))
                handle.windingRule = .evenOdd; handle.fill()
                mark(NSRect(x: 23, y: 2.5, width: 12.5, height: 13))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
