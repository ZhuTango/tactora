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
        let a = bitmap(idle), b = bitmap(active)
        var indicatorPixels = 0
        for y in 0..<18 {
            for x in 0..<18 {
                precondition(abs(a.colorAt(x: x, y: y)!.alphaComponent - b.colorAt(x: x, y: y)!.alphaComponent) < 0.01, "Primary mark must remain unchanged")
            }
            for x in 23..<40 where b.colorAt(x: x, y: y)!.alphaComponent > 0.1 { indicatorPixels += 1 }
        }
        precondition(indicatorPixels > 20, "Active state must add a visible icon on the right")
        precondition(ToolIcon.statusImage(awake: true) === active, "Reuse cached images")
        try b.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/status-icon-active.png"))
        print("PASS: unchanged main mark, right-side awake indicator, template rendering and caching")
    }
}
