import AppKit

@main struct OCRShortcutChecks {
    static func fixture(_ text: String, dark: Bool, size: CGFloat, bold: Bool) -> Data {
        let image = NSImage(size: NSSize(width: 900, height: 120))
        image.lockFocus()
        (dark ? NSColor.black : NSColor.white).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 120).fill()
        (text as NSString).draw(at: NSPoint(x: 20, y: 45), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: dark ? NSColor.white : NSColor.black
        ])
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    @MainActor static func main() throws {
        var failures = [String]()
        for (dark, size, bold) in [(false, CGFloat(14), false), (true, CGFloat(14), true), (false, CGFloat(20), true), (true, CGFloat(24), false)] {
            let output = try OCRRecognition.recognize(fixture("快捷键 ⌘⇧D 框选截图", dark: dark, size: size, bold: bold))
            if !output.contains("⌘⇧D") { failures.append("dark=\(dark) size=\(size) bold=\(bold): \(output)") }
        }
        for text in ["9个D 88个D ％个D", "田由甲申中 2026", "const userId = getUserId(); price: 128.50"] {
            let output = try OCRRecognition.recognize(fixture(text, dark: false, size: 18, bold: false))
            if output.contains("⌘") || output.contains("⇧") { failures.append("False symbol replacement: \(text) → \(output)") }
        }
        if CommandLine.arguments.count > 1 {
            let output = try OCRRecognition.recognize(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            if !output.contains("⌘⇧D") || !output.contains("1.16.0") || !output.contains("本地识别中英文并复制") { failures.append("Original screenshot: \(output)") }
            print("Original screenshot OCR:\n\(output)")
        }
        for failure in failures { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
        precondition(failures.isEmpty, "Shortcut glyph regression failed")
        print("PASS: shortcut glyphs across size, weight and theme; ordinary numbers, Chinese and code are not converted to modifiers")
    }
}
