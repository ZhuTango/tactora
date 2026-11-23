import AppKit

@main
struct ToolIconChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        for title in ["—° —", "57° 2851", "100° 5776", "125° 20000", "57° 0"] {
            ToolIcon.setStatusImage(ToolIcon.fanReadingsImage(title), on: item)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(item.length == 34, "Every reading must reserve its entire 32-point canvas plus compact padding")
            precondition(item.button!.bounds.width >= 34, "Native button must occupy the reserved width")
            let imageRect = item.button!.cell!.imageRect(forBounds: item.button!.bounds)
            precondition(item.button!.bounds.contains(imageRect), "Artwork must remain inside its menu item")
        }
        for awake in [false, true, false] {
            let icon = ToolIcon.statusImage(awake: awake)
            ToolIcon.setStatusImage(icon, on: item)
            precondition(item.length == (awake ? 36 : 22), "Awake state must release its extra width when stopped")
        }
        print("PASS: native status-item widths, reading changes and artwork containment")
        func bitmap(_ image: NSImage) -> NSBitmapImageRep {
            let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            return result
        }
        let moduleSymbols = ["doc.on.clipboard", "photo", "square.stack.3d.up", "macwindow",
                             "display.sun", "text.viewfinder", "textformat", "keyboard",
                             "calendar", "fanblades", "camera.viewfinder"]
        var silhouettes = Set<[Bool]>()
        for symbol in moduleSymbols {
            let image = ToolIcon.featureImage(symbol: symbol)
            let pixels = bitmap(image)
            let mask = (0..<20).flatMap { y in
                (0..<20).map { x in pixels.colorAt(x: x, y: y)!.alphaComponent > 0.5 }
            }
            precondition(image.isTemplate && mask.contains(true), "Missing module icon: \(symbol)")
            precondition(silhouettes.insert(mask).inserted, "Duplicate module silhouette: \(symbol)")
        }
        print("PASS: all eleven module icons render with distinct template silhouettes")
        let idle = ToolIcon.statusImage(awake: false)
        let active = ToolIcon.statusImage(awake: true)
        precondition(idle.isTemplate && active.isTemplate)
        precondition(idle.size.width == 18 && active.size.width == 34)
        let a = bitmap(idle), b = bitmap(active)
        var indicatorPixels = 0
        for y in 0..<18 {
            for x in 0..<18 {
                precondition(abs(a.colorAt(x: x, y: y)!.alphaComponent - b.colorAt(x: x, y: y)!.alphaComponent) < 0.01, "Primary mark must remain unchanged")
            }
            for x in 21..<34 where b.colorAt(x: x, y: y)!.alphaComponent > 0.1 { indicatorPixels += 1 }
        }
        precondition(indicatorPixels >= 20, "Active state must add a visible sun on the right")
        precondition(ToolIcon.statusImage(awake: true) === active, "Reuse cached images")
        try b.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/status-icon-active.png"))
        for title in ["54° 2146", "100° 5776", "—° —"] {
            let reading = ToolIcon.fanReadingsImage(title)
            precondition(reading.isTemplate && reading.size == NSSize(width: 32, height: 22))
            let pixels = bitmap(reading)
            for row in [0..<11, 11..<22] {
                precondition(row.contains { y in (0..<32).contains { x in
                    pixels.colorAt(x: x, y: y)!.alphaComponent > 0.1
                } }, "Both reading rows must render")
            }
        }
        let reading = bitmap(ToolIcon.fanReadingsImage("54° 2146"))
        try reading.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/fan-readings.png"))
        print("PASS: unchanged main mark, right-side awake indicator, template rendering and caching")
    }
}
