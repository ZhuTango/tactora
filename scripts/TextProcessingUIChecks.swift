import AppKit

@main struct TextProcessingUIChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
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
    struct CheckFailure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message: message) }
    }
    @MainActor static func choose(_ value: TextToolMode, in root: NSView) {
        let item = views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.tool.\(value.rawValue)" }!
        NSApp.sendAction(item.action!, to: item.target, from: item)
    }
    @MainActor static func checkEditingKeys(_ panel: TextProcessingWindow, window: NSWindow) async throws {
        let general = NSPasteboard.general
        let originalBoard: [NSPasteboardItem] = general.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        } ?? []
        defer { general.clearContents(); general.writeObjects(originalBoard) }
        func editingKey(_ key: String, code: UInt16, shift: Bool = false, editor: NSTextView) async throws {
            window.makeFirstResponder(editor)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            try require(window.performKeyEquivalent(with: event), "Text editor must handle Command-\(key)")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        general.clearContents(); general.setString("快捷粘贴", forType: .string)
        try await editingKey("v", code: 9, editor: panel.input)
        try require(panel.input.string == "快捷粘贴", "Command-V must paste into editor")
        try await editingKey("a", code: 0, editor: panel.input)
        try await editingKey("c", code: 8, editor: panel.input)
        try require(general.string(forType: .string) == "快捷粘贴", "Copy selected text")
        try await editingKey("x", code: 7, editor: panel.input)
        try require(panel.input.string.isEmpty, "Cut selected text")
        try await editingKey("z", code: 6, editor: panel.input)
        try require(panel.input.string == "快捷粘贴", "Undo cut")
        try await editingKey("z", code: 6, shift: true, editor: panel.input)
        try require(panel.input.string.isEmpty, "Redo cut")
        choose(.compare, in: window.contentView!)
        panel.setInput("原文")
        panel.comparison.string = ""
        general.clearContents(); general.setString("新文", forType: .string)
        try await editingKey("v", code: 9, editor: panel.comparison)
        try await ready(panel)
        try require(panel.comparison.string == "新文" && panel.output.string.contains("+ 新文"), "Paste comparison updates diff: input=\(panel.comparison.string), output=\(panel.output.string)")
        choose(.automatic, in: window.contentView!)
        try await ready(panel)
        panel.comparison.string = ""
        // Read-only output accepts selection/copy but must ignore a paste.
        panel.output.string = "只读结果"
        try await editingKey("a", code: 0, editor: panel.output)
        try await editingKey("c", code: 8, editor: panel.output)
        try require(general.string(forType: .string) == "只读结果", "Copy output")
        general.clearContents(); general.setString("不可覆盖", forType: .string)
        try await editingKey("v", code: 9, editor: panel.output)
        try require(panel.output.string == "只读结果", "Output remains read-only")
        panel.setInput("")
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
        try await checkEditingKeys(panel, window: window)
        let descendants = views(root)
        let copy = descendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.copy" }!
        let clear = descendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.clear" }!
        let operation = descendants.compactMap { $0 as? NSPopUpButton }.first!
        precondition(panel.input.string.isEmpty, "Opening must not read the clipboard automatically")
        panel.setInput("clipboard sentinel")
        try await ready(panel)
        precondition(panel.input.string == "clipboard sentinel" && panel.output.string == "clipboard sentinel")
        func choose(_ value: TextToolMode) { Self.choose(value, in: root) }
        panel.setInput("{\"name\":\"方寸\"}")
        try await ready(panel)
        precondition(panel.output.string.contains("\n") && panel.output.string.contains("方寸"), "Auto formats JSON")
        panel.setInput("1700000000000")
        try await ready(panel)
        precondition(panel.output.string.contains("2023-11-14 22:13:20"), "Auto timestamp includes UTC")
        choose(.json); panel.setInput("{oops}")
        try await ready(panel)
        precondition(panel.output.string.isEmpty && !copy.isEnabled, "Invalid JSON cannot copy stale result")
        choose(.compare)
        panel.setInput("old\nkeep")
        panel.comparison.string = "new\nkeep"
        panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.comparison))
        try await ready(panel)
        precondition(panel.output.string.contains("- old") && panel.output.string.contains("+ new"))
        choose(.basic)
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
        let sample = descendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "text.example" }!
        NSApp.sendAction(sample.action!, to: sample.target, from: sample)
        precondition(panel.input.string == "方寸\nTactora\n方寸\n文本快捷处理", "Examples cannot overwrite existing input")
        choose(.json); choose(.basic)
        precondition(operation.indexOfSelectedItem == 3, "Each tool remembers its operation")
        choose(.compare)
        panel.comparison.string = "不同的版本"
        panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.comparison))
        try await ready(panel)
        precondition(panel.comparison.string == "不同的版本" && panel.output.string.contains("+ 不同的版本"))
        window.setContentSize(NSSize(width: 900, height: 500)); root.layoutSubtreeIfNeeded()
        let left = panel.input.enclosingScrollView!, right = panel.comparison.enclosingScrollView!, result = panel.output.enclosingScrollView!
        let l = left.convert(left.bounds, to: root), r = right.convert(right.bounds, to: root), o = result.convert(result.bounds, to: root)
        precondition(l.width > 200 && r.width > 200 && o.width > 600 && l.minY >= o.maxY, "Compare uses two inputs above a full-width result")
        let compareBitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: compareBitmap)
        try compareBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/text-tools-compare.png"))
        choose(.basic)
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
        let oldDirectPaste = UserDefaults.standard.object(forKey: "clipboardDirectPaste")
        UserDefaults.standard.set(true, forKey: "clipboardDirectPaste")
        defer {
            if let oldDirectPaste { UserDefaults.standard.set(oldDirectPaste, forKey: "clipboardDirectPaste") }
            else { UserDefaults.standard.removeObject(forKey: "clipboardDirectPaste") }
        }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent()) }
        // Persistence and conflicts must not require system permission or overwrite a prior binding.
        ToolFeature.text.setEnabled(false, in: defaults)
        let shortcut = TextToolsShortcut(defaults: defaults)
        let custom = ClipboardShortcut(keyCode: 3, modifiers: 768, label: "⌘⇧F")
        precondition(shortcut.setShortcut(custom))
        precondition(TextToolsShortcut.savedContains(custom, defaults: defaults))
        shortcut.conflicts = { _ in true }
        precondition(!shortcut.setShortcut(TextToolsShortcut.defaultShortcut))
        precondition(shortcut.shortcut == custom, "Conflicts must preserve the previous shortcut")
        precondition(shortcut.setShortcut(nil))
        precondition(TextToolsShortcut.savedShortcut(defaults: defaults) == nil)
        shortcut.conflicts = nil
        precondition(shortcut.setShortcut(TextToolsShortcut.defaultShortcut))
        let reloaded = TextToolsShortcut(defaults: defaults)
        precondition(reloaded.shortcut == TextToolsShortcut.defaultShortcut)
        shortcut.stop(); reloaded.stop()
        ToolFeature.text.setEnabled(true, in: defaults)
        let history = ClipboardStore(url: historyURL, pasteboard: board)
        try history.setEnabled(true)
        try history.copyOCRText("方寸")
        panel.setInput("before old after")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(panel.input)
        panel.input.setSelectedRange(NSRange(location: 7, length: 3))
        try await Task.sleep(nanoseconds: 200_000_000)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(panel.input)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier, "Harness must be frontmost")
        precondition(NSApp.keyWindow === window, "Harness editor must be key")
        let routed = ClipboardWindow(store: history)
        var received: String?
        routed.onProcessText = { received = $0 }
        routed.present()
        let processItem = views(routed.window!.contentView!).compactMap(\.menu).flatMap(\.items).first { $0.action == NSSelectorFromString("processText:") }!
        NSApp.sendAction(processItem.action!, to: processItem.target, from: processItem)
        precondition(received == "方寸" && routed.window?.isVisible == false, "Context action passes original text and closes history")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(panel.input)
        panel.input.setSelectedRange(NSRange(location: 7, length: 3))
        let clipboard = ClipboardWindow(store: history)
        clipboard.present()
        // Dismiss a failure alert so this regression fails unattended on the old implementation.
        let alertTimeout = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }
        RunLoop.main.add(alertTimeout, forMode: .modalPanel)
        NSApp.sendAction(NSSelectorFromString("copySelected"), to: clipboard, from: nil)
        alertTimeout.invalidate()
        precondition(panel.input.string == "before 方寸 after", "Clipboard must paste back into the original internal editor and selection")
        try await ready(panel)
        precondition(panel.output.string == "before 方寸 after", "Internal paste must notify preview")
        precondition(window.firstResponder === panel.input, "Internal paste must restore editor focus")
        panel.input.undoManager?.undo()
        precondition(panel.input.string == "before old after", "Internal paste must support undo")
        panel.setInput("do not deliver after close")
        panel.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(panel.input.string.isEmpty && panel.output.string.isEmpty)
        ToolFeature.text.setEnabled(false, in: defaults)
        panel.present(); precondition(!window.isVisible)
        print("PASS: auto JSON/timestamp, invalid JSON, diff preview, shortcut persistence/conflicts/clear, explicit paste, non-destructive preview, explicit copy, operation change, stale-result cancellation, size guard, clear/close cleanup and feature disable")
    }
}
