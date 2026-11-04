import AppKit

@main
struct ToolIconChecks {
    @MainActor static func main() throws {
        func bitmap(_ image: NSImage) -> NSBitmapImageRep {
            let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            return result
        }
        let idle = ToolIcon.statusImage(awake: false)
        let active = ToolIcon.statusImage(awake: true)
        precondition(idle.isTemplate && active.isTemplate)
        precondition(idle.size == active.size && active.size.width == 34)
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
