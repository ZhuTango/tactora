import AppKit

@main struct OCRChecks {
    static func fixture(_ text: String) -> Data {
        let image = NSImage(size: NSSize(width: 1000, height: 260))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 260).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    @MainActor static func main() throws {
        func line(_ text: String, _ y: CGFloat, x: CGFloat = 0.1, width: CGFloat = 0.8) -> OCRTextLine {
            OCRTextLine(text: text, bounds: CGRect(x: x, y: y, width: width, height: 0.04))
        }
        let chinese = [line("这是一段因排版而", 0.8), line("换行的中文内容。", 0.75)]
        precondition(OCRTextLayout.assemble(chinese, mode: .smart) == "这是一段因排版而换行的中文内容。")
        precondition(OCRTextLayout.assemble(chinese, mode: .original) == "这是一段因排版而\n换行的中文内容。")
        precondition(OCRTextLayout.assemble(chinese, mode: .singleLine) == "这是一段因排版而换行的中文内容。")
        precondition(OCRTextLayout.assemble([line("This wraps across", 0.8), line("two lines", 0.75)], mode: .smart) == "This wraps across two lines")
        precondition(OCRTextLayout.assemble([line("第一段", 0.8), line("第二段", 0.65)], mode: .smart) == "第一段\n\n第二段")
        for text in ["1. 第一项", "• 第一项", "let value = 1", "return value;"] {
            precondition(OCRTextLayout.assemble([line(text, 0.8), line("下一行", 0.75)], mode: .smart).contains("\n"))
        }
        precondition(OCRTextLayout.assemble([line("标题", 0.8, width: 0.2), line("正文内容", 0.75)], mode: .smart) == "标题\n正文内容")
        precondition(OCRTextLayout.assemble([line("left", 0.8, width: 0.3), line("right", 0.8, x: 0.6, width: 0.3)], mode: .smart) == "left\nright")
        precondition(OCRTextLayout.assemble([line("Hello", 0.8), line(", world", 0.75)], mode: .singleLine) == "Hello, world")
        precondition(OCRTextLayout.assemble([], mode: .smart).isEmpty)
        let suite = "ocr-layout-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        precondition(OCRLineBreakMode.saved(in: prefs) == .smart)
        prefs.set(false, forKey: "ocrKeepLineBreaks")
        precondition(OCRLineBreakMode.saved(in: prefs) == .singleLine)
        prefs.set(true, forKey: "ocrKeepLineBreaks")
        precondition(OCRLineBreakMode.saved(in: prefs) == .original)
        for mode in OCRLineBreakMode.allCases {
            prefs.set(mode.rawValue, forKey: "ocrLineBreakMode")
            precondition(OCRLineBreakMode.saved(in: prefs) == mode)
        }
        print("PASS: smart Chinese/English wrapping, paragraphs, lists/code, columns, punctuation and preference migration")
        let image = fixture("Tactora OCR 2026\n截图识字测试")
        let result = try OCRRecognition.recognize(image, mode: .original)
        precondition(result.contains("Tactora OCR 2026"), "Recognize actual pixels, not an empty result")
        precondition(result.contains("截图识字测试"), "Recognize simplified Chinese locally")
        precondition(result.contains("\n"))
        let single = try OCRRecognition.recognize(image, keepLineBreaks: false)
        precondition(!single.contains("\n") && single.contains("Tactora"))
        let wrapped = fixture("A local tool can join\nwrapped English text")
        let smartText = try OCRRecognition.recognize(wrapped, mode: .smart)
        let wrappedOriginal = try OCRRecognition.recognize(wrapped, mode: .original)
        let wrappedSingle = try OCRRecognition.recognize(wrapped, mode: .singleLine)
        precondition(wrappedOriginal.contains("\n") && !smartText.contains("\n") && smartText == wrappedSingle, "Smart layout must merge actual OCR lines")
        let blank = try OCRRecognition.recognize(fixture(""))
        precondition(blank == "")
        do { _ = try OCRRecognition.recognize(Data()); fatalError("Invalid image accepted") } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(url: root.appendingPathComponent("clipboard.json"), pasteboard: board)
        let recordedWhileOff = try store.copyOCRText(result)
        precondition(!recordedWhileOff && store.entries.isEmpty && board.string(forType: .string) == result)
        try store.setEnabled(true)
        store.poll(); precondition(store.entries.isEmpty, "Enabling later must not capture a previous OCR result")
        let recorded = try store.copyOCRText(result)
        precondition(recorded && store.entries.count == 1 && store.entries[0].origin == "ocr")
        let id = store.entries[0].id
        try store.setPinned(true, for: id)
        _ = try store.copyOCRText(result)
        precondition(store.entries.count == 1 && store.entries[0].id == id && store.entries[0].isPinned)
        let restored = ClipboardStore(url: root.appendingPathComponent("clipboard.json"), pasteboard: board)
        precondition(restored.entries.first?.origin == "ocr")
        store.setSuspended(true)
        let suspended = try store.copyOCRText("Suspended OCR")
        precondition(!suspended && store.entries.count == 1 && board.string(forType: .string) == "Suspended OCR")
        do { _ = try store.copyOCRText("  "); fatalError("Empty OCR overwritten clipboard") } catch {}
        precondition(board.string(forType: .string) == "Suspended OCR")
        store.stop()
        try image.write(to: URL(fileURLWithPath: ".build/ocr-fixture.png"))
        print("PASS: OCR copies while recording disabled, preserves source/pins, persists and respects suspension")
        print("PASS: real local English/Chinese OCR, line breaks, blank and invalid images")
    }
}
