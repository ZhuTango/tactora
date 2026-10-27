import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let inset = side * 0.07
        let bounds = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: side * 0.20, yRadius: side * 0.20)
        NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.56, blue: 0.52, alpha: 1),
                   ending: NSColor(srgbRed: 0.09, green: 0.25, blue: 0.40, alpha: 1))!.draw(in: shape, angle: -45)
        let symbol = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [.white]))!
        symbol.draw(in: NSRect(x: side * 0.22, y: side * 0.24, width: side * 0.56, height: side * 0.52))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
