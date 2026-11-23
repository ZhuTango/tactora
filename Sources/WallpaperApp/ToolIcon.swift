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
        p.move(to: NSPoint(x: 8, y: 52))
        p.curve(to: NSPoint(x: 53, y: 6), controlPoint1: NSPoint(x: 8, y: 25), controlPoint2: NSPoint(x: 27, y: 6))
        p.curve(to: NSPoint(x: 78, y: 22), controlPoint1: NSPoint(x: 68, y: 6), controlPoint2: NSPoint(x: 78, y: 12))
        p.curve(to: NSPoint(x: 65, y: 29), controlPoint1: NSPoint(x: 78, y: 27), controlPoint2: NSPoint(x: 73, y: 30))
        p.curve(to: NSPoint(x: 39, y: 28), controlPoint1: NSPoint(x: 55, y: 27), controlPoint2: NSPoint(x: 48, y: 25))
        p.curve(to: NSPoint(x: 27, y: 58), controlPoint1: NSPoint(x: 26, y: 35), controlPoint2: NSPoint(x: 22, y: 48))
        p.curve(to: NSPoint(x: 33, y: 63), controlPoint1: NSPoint(x: 29, y: 61), controlPoint2: NSPoint(x: 31, y: 62))
        p.curve(to: NSPoint(x: 15, y: 66), controlPoint1: NSPoint(x: 25, y: 61), controlPoint2: NSPoint(x: 19, y: 66))
        p.curve(to: NSPoint(x: 8, y: 52), controlPoint1: NSPoint(x: 11, y: 66), controlPoint2: NSPoint(x: 8, y: 59))
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

    static func appImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor(srgbRed: 0.105, green: 0.11, blue: 0.115, alpha: 1).setFill()
            rounded(NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84), radius: size * 0.19).fill()
            mark(NSRect(x: size * 0.205, y: size * 0.205, width: size * 0.59, height: size * 0.59), color: .white)
            return true
        }
    }

    private static var featureCache: [String: NSImage] = [:]
    // All module glyphs share a 24-unit grid. Opposing rounded ends and open
    // corners echo the brand mark while keeping the silhouettes distinct at 18 pt.
    private static let glyphs: [String: String] = [
        "doc.on.clipboard": #"<path d="M7 5H6a3 3 0 0 0-3 3v10a3 3 0 0 0 3 3h9q6 0 6-6V8a3 3 0 0 0-3-3h-1"/><rect x="8" y="2" width="8" height="5" rx="2"/><path d="M8 13h8m-8 4h4"/>"#,
        "photo": #"<rect x="2" y="4" width="20" height="16" rx="4"/><path d="M3 16q4-8 9-2t9-2"/><circle cx="16" cy="9" r="1.6" fill="black" stroke="none"/>"#,
        "square.stack.3d.up": #"<path d="M3 11q0-5 5-5h11m-4-4 4 4-4 4M21 13q0 5-5 5H5m4-4-4 4 4 4"/>"#,
        "macwindow": #"<rect x="2" y="4" width="20" height="16" rx="4"/><path d="M10 4v16m0-8h12"/>"#,
        "display.sun": #"<path d="M3 11h13v3a6.5 6.5 0 0 1-13 0zm13 1h2a2.5 2.5 0 0 1 0 5h-2M6 7c-2-2 2-3 0-5m5 5c-2-2 2-3 0-5"/>"#,
        "text.viewfinder": #"<path d="M3 8V7q0-4 4-4h1m8 0h1q4 0 4 4v1M3 16v1q0 4 4 4h1m8 0h1q4 0 4-4v-1M8 15l4-8 4 8m-6-2h4"/>"#,
        "textformat": #"<path d="M3 5h13M9 5v14m-4 0h8m2-5 5-6 2 2-5 6-3 1Z"/>"#,
        "keyboard": #"<rect x="1.5" y="5" width="21" height="14" rx="4"/><path d="M6 10h.4m3.4 0h.4m3.4 0h.4m3.4 0h.4M8 15h8"/>"#,
        "calendar": #"<rect x="3" y="5" width="18" height="16" rx="4"/><path d="M8 3v4m8-4v4M3 11h18"/><rect x="7" y="14" width="4" height="4" rx="1" fill="black" stroke="none"/>"#,
        "fanblades": ##"<g fill="black" stroke="none"><path id="blade" d="M10 9C6 8 6 4 9 2.5c3.3-1.5 7-.6 9 2-3.5-.1-4.7 2-5.1 4.2Z"/><use href="#blade" transform="rotate(120 12 12)"/><use href="#blade" transform="rotate(240 12 12)"/><circle cx="12" cy="12" r="2"/></g>"##,
        "camera.viewfinder": #"<path d="M7 2v11q0 4 4 4h11M2 7h11q4 0 4 4v11m2-17 2-2"/>"#
    ]

    static func featureImage(symbol: String) -> NSImage {
        if let cached = featureCache[symbol] { return cached }
        guard let glyph = glyphs[symbol] else {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 20, height: 20))
        }
        let artwork = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24">
          <g fill="none" stroke="black" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">
            \(glyph)
          </g>
        </svg>
        """
        let image = NSImage(data: Data(artwork.utf8))
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 20, height: 20))
        image.isTemplate = true
        featureCache[symbol] = image
        return image
    }

    /// Keep artwork inside its item with compact padding and a usable minimum width.
    /// Explicit lengths avoid relayout based on changing template-image ink bounds.
    static func setStatusImage(_ image: NSImage, on item: NSStatusItem) {
        let length = max(22, image.size.width + 2)
        if item.length != length { item.length = length }
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        if button.image !== image { button.image = image }
    }

    /// A fixed canvas keeps neighbouring menu items still as readings change.
    static func fanReadingsImage(_ title: String) -> NSImage {
        let values = title.split(separator: " ").map(String.init)
        let image = NSImage(size: NSSize(width: 32, height: 22), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: rect).addClip()
            for (index, value) in values.prefix(2).enumerated() {
                let text = NSAttributedString(string: value, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.black
                ])
                let size = text.size()
                let rowY: CGFloat = index == 0 ? 11 : 0
                text.draw(at: NSPoint(x: (32 - size.width) / 2,
                                      y: rowY + (11 - size.height) / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let idle = makeStatusImage(awake: false)
    private static let awake = makeStatusImage(awake: true)
    static func statusImage(awake: Bool) -> NSImage { awake ? self.awake : idle }
    private static func makeStatusImage(awake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: awake ? 34 : 18, height: 18), flipped: false) { _ in
            mark(NSRect(x: 1, y: 1, width: 16, height: 16))
            if awake {
                let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
                sun?.draw(in: NSRect(x: 21, y: 3, width: 12, height: 12))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
