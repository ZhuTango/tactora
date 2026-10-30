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
        let image = fixture("Tactora OCR 2026\n截图识字测试")
        let result = try OCRRecognition.recognize(image)
        precondition(result.contains("Tactora OCR 2026"), "Recognize actual pixels, not an empty result")
        precondition(result.contains("截图识字测试"), "Recognize simplified Chinese locally")
        precondition(result.contains("\n"))
        let single = try OCRRecognition.recognize(image, keepLineBreaks: false)
        precondition(!single.contains("\n") && single.contains("Tactora"))
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
