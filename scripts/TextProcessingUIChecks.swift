import AppKit

@main struct TextProcessingUIChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await check(); app.stop(nil); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func ready(_ panel: TextProcessingWindow) async throws {
        for _ in 0..<50 {
            if !panel.processing { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        preconditionFailure("Preview timed out")
    }
    @MainActor static func check() async throws {
        let suite = "text-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("clipboard sentinel", forType: .string)
        let panel = TextProcessingWindow(defaults: defaults, pasteboard: board)
        panel.present()
        let window = panel.window!, root = window.contentView!
        let descendants = views(root)
        let copy = descendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.copy" }!
        let clear = descendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.clear" }!
        let paste = descendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.paste" }!
        let operation = descendants.compactMap { $0 as? NSPopUpButton }.first!
        precondition(panel.input.string.isEmpty, "Opening must not read the clipboard automatically")
        NSApp.sendAction(paste.action!, to: paste.target, from: paste)
        try await ready(panel)
        precondition(panel.input.string == "clipboard sentinel" && panel.output.string == "clipboard sentinel")
        panel.setInput("  原文\nTactora  ")
        precondition(!copy.isEnabled, "No stale copying while preview is pending")
        try await ready(panel)
        precondition(panel.output.string == "原文\nTactora" && panel.input.string == "  原文\nTactora  ")
        precondition(board.string(forType: .string) == "clipboard sentinel", "Preview must not replace clipboard")
        NSApp.sendAction(copy.action!, to: copy.target, from: copy)
        precondition(board.string(forType: .string) == "原文\nTactora")
        operation.selectItem(at: 3)
        NSApp.sendAction(operation.action!, to: operation.target, from: operation)
        panel.setInput("方寸\nTactora\n方寸\n文本快捷处理")
        try await ready(panel)
        precondition(panel.output.string == "方寸\nTactora\n文本快捷处理")
        precondition(!panel.output.isEditable)
        window.display(); root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/text-tools-preview.png"))
        panel.setInput("first"); panel.setInput("latest")
        try await ready(panel); precondition(panel.output.string == "latest")
        precondition(!panel.textView(panel.input, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: String(repeating: "字", count: TextProcessor.maximumBytes)), "Direct paste must obey the same byte limit")
        panel.setInput(String(repeating: "字", count: TextProcessor.maximumBytes))
        precondition(panel.input.string == "latest", "Oversized paste must preserve original")
        NSApp.sendAction(clear.action!, to: clear.target, from: clear)
        precondition(panel.input.string.isEmpty && panel.output.string.isEmpty && !copy.isEnabled)
        panel.setInput("keep undo")
        window.makeFirstResponder(panel.input)
        panel.input.insertText("", replacementRange: NSRange(location: 0, length: (panel.input.string as NSString).length))
        precondition(panel.input.string.isEmpty)
        precondition(panel.input.undoManager?.canUndo == true, "Deleting all input must remain undoable")
        panel.input.undoManager?.undo()
        precondition(panel.input.string == "keep undo", "Undo must restore accidentally deleted original")
        panel.setInput("do not deliver after close")
        panel.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(panel.input.string.isEmpty && panel.output.string.isEmpty)
        ToolFeature.text.setEnabled(false, in: defaults)
        panel.present(); precondition(!window.isVisible)
        print("PASS: explicit paste, non-destructive preview, explicit copy, operation change, stale-result cancellation, size guard, clear/close cleanup and feature disable")
    }
}
