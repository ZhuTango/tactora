import AppKit
import Carbon
import ServiceManagement

@main
struct Preview {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--scan-only") {
            print("SCAN start")
            let found = await Task.detached { AppSwitcher.discover() }.value
            print("SCAN found", found.count)
            return
        }
        if CommandLine.arguments.contains("--activation-check") {
            _ = NSApplication.shared
            let previous = NSWorkspace.shared.frontmostApplication
            defer { previous?.activate(options: []) }
            let suite = "switcher-activation-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = AppSwitcher(defaults: defaults, start: false)
            manager.panelEnabled = false
            let finder = SwitcherApp(id: "com.apple.finder", name: "Finder", path: "/System/Library/CoreServices/Finder.app")
            try manager.configure(finder, shortcut: nil, show: true)
            manager.activate(finder.id)
            for _ in 0..<30 {
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finder.id { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            precondition(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finder.id)
            let runningFinder = NSRunningApplication.runningApplications(withBundleIdentifier: finder.id).first!
            manager.activate(finder.id)
            for _ in 0..<30 {
                if runningFinder.isHidden { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard runningFinder.isHidden else { throw NSError(domain: "AppToggleTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Second shortcut must hide the frontmost app"]) }
            manager.activate(finder.id)
            for _ in 0..<30 {
                if runningFinder.isActive && !runningFinder.isHidden { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            precondition(runningFinder.isActive && !runningFinder.isHidden)
            print("PASS: activates, hides and restores Finder without minimization or accessibility permissions")
            return
        }
        for path in ["/System/Library/CoreServices/CoreLocationAgent.app", "/System/Library/CoreServices/Coverage Details.app", "/System/Library/CoreServices/Database Events.app"] {
            if let bundle = Bundle(path: path) { precondition(!AppSwitcher.hasApplicationIcon(bundle)) }
        }
        for path in ["/System/Applications/Contacts.app", "/Applications/Cursor.app"] {
            if let bundle = Bundle(path: path) { precondition(AppSwitcher.hasApplicationIcon(bundle)) }
        }
        print("PASS: automatic discovery excludes generic-icon system helpers and keeps normal app icons")
        var checks = 0
        var sends = 0
        let delayed = await ClipboardPasteDelivery.deliver(target: 2, own: 1,
            frontmost: { checks > 6 ? 2 : 1 }, trusted: { true }, alive: { true },
            send: { sends += 1 }, pause: { checks += 1 })
        precondition(delayed && sends == 1 && checks == 8, "Paste must survive activation slower than 200 ms")
        let diverted = await ClipboardPasteDelivery.deliver(target: 2, own: 1,
            frontmost: { 3 }, trusted: { true }, alive: { true }, send: { sends += 1 }, pause: {})
        let denied = await ClipboardPasteDelivery.deliver(target: 2, own: 1,
            frontmost: { 2 }, trusted: { false }, alive: { true }, send: { sends += 1 }, pause: {})
        let timeout = await ClipboardPasteDelivery.deliver(target: 2, own: 1,
            frontmost: { 1 }, trusted: { true }, alive: { true }, send: { sends += 1 }, pause: {})
        precondition(!diverted && !denied && !timeout && sends == 1)
        print("PASS: delayed focus paste, third-app cancellation, permission denial and timeout")
        let previousLanguage = AppLanguage.selection
        AppLanguage.selection = "zh-Hans"
        defer { AppLanguage.selection = previousLanguage }
        let shortcut = GlobalClipboardShortcut()
        var fired = false
        shortcut.action = { fired = true }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-preview-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let board = NSPasteboard(name: NSPasteboard.Name("clipboard-preview-" + UUID().uuidString))
        let store = ClipboardStore(url: root.appendingPathComponent("history.json"), pasteboard: board)
        defer { store.stop(); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        try store.setEnabled(true); store.stop()
        for text in ["周会记录：先确认需求范围，再完成实现与验证。", "https://developer.apple.com/documentation/appkit", "一段可以反复使用的文字\n支持中文搜索与多行内容。"] {
            board.clearContents(); board.setString(text, forType: .string); store.poll()
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 1280, bitsPerPixel: 32)!
        for x in 0..<320 { for y in 0..<180 {
            bitmap.setColor(NSColor(deviceRed: CGFloat(x)/400, green: 0.5, blue: CGFloat(y)/220, alpha: 1), atX: x, y: y)
        } }
        board.clearContents(); board.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png); store.poll()
        let file = root.appendingPathComponent("设计说明.md").standardizedFileURL
        try Data("fixture".utf8).write(to: file)
        board.clearContents(); board.writeObjects([file as NSURL]); store.poll()
        let panel = ClipboardWindow(store: store)
        store.onChange = { [weak panel] in panel?.refresh() }
        panel.present()
        if shortcut.register() {
            var event: EventRef?
            CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
            if let event {
                var id = EventHotKeyID(signature: 0x4c54534b, id: shortcut.identifier)
                SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
                SendEventToEventTarget(event, GetApplicationEventTarget()); ReleaseEvent(event)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            precondition(fired)
            print("PASS: global shortcut registration and application event dispatch")
        } else { print("SKIP: global shortcut already reserved by another application") }
        // Independent Carbon registrations must dispatch only to their matching owner.
        let appKey = GlobalClipboardShortcut()
        var appFired = 0
        appKey.action = { appFired += 1 }
        let testKey = ClipboardShortcut(keyCode: 17, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), label: "⌃⌥⇧⌘T")
        precondition(appKey.register(testKey))
        fired = false
        var hotEvent: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &hotEvent)
        var appID = EventHotKeyID(signature: 0x4c54534b, id: appKey.identifier)
        SetEventParameter(hotEvent!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &appID)
        SendEventToEventTarget(hotEvent!, GetApplicationEventTarget()); ReleaseEvent(hotEvent!)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(appFired == 1 && !fired)
        let inlineRecorder = SwitcherShortcutRecorder()
        let inlineRecorderWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        inlineRecorderWindow.contentView = inlineRecorder
        var recorded: ClipboardShortcut?
        var didClear = false
        inlineRecorder.onRecord = { recorded = $0; didClear = $0 == nil }
        inlineRecorder.beginRecording()
        precondition(inlineRecorder.isRecording && GlobalClipboardShortcut.isRecording)
        var probe: EventHotKeyRef?
        precondition(RegisterEventHotKey(testKey.keyCode, testKey.modifiers, EventHotKeyID(signature: 0x54455354, id: 9), GetApplicationEventTarget(), 0, &probe) == noErr)
        UnregisterEventHotKey(probe!)
        let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: inlineRecorderWindow.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        inlineRecorder.handleKey(keyEvent)
        precondition(recorded?.label == "⌥W" && !inlineRecorder.isRecording && !GlobalClipboardShortcut.isRecording)
        inlineRecorder.beginRecording()
        let inlineEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: inlineRecorderWindow.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        inlineRecorder.handleKey(inlineEscape)
        precondition(!inlineRecorder.isRecording && recorded?.label == "⌥W")
        inlineRecorder.beginRecording()
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: inlineRecorderWindow.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!
        inlineRecorder.handleKey(delete)
        precondition(didClear && !GlobalClipboardShortcut.isRecording)
        var restoredProbe: EventHotKeyRef?
        precondition(RegisterEventHotKey(testKey.keyCode, testKey.modifiers, EventHotKeyID(signature: 0x54455354, id: 10), GetApplicationEventTarget(), 0, &restoredProbe) != noErr)
        inlineRecorder.beginRecording()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: inlineRecorderWindow)
        precondition(!inlineRecorder.isRecording && !GlobalClipboardShortcut.isRecording)
        print("PASS: inline shortcut recording, Escape cancellation, Backspace clearing, focus loss and hotkey restoration")
        var hold = OptionHoldState()
        precondition(!hold.visible(optionOnly: true, now: 1))
        precondition(!hold.visible(optionOnly: true, now: 1.3))
        precondition(hold.visible(optionOnly: true, now: 1.5))
        hold.suppress(); precondition(!hold.visible(optionOnly: true, now: 2))
        precondition(!hold.visible(optionOnly: false, now: 3))
        precondition(!hold.visible(optionOnly: true, now: 4))
        precondition(hold.visible(optionOnly: true, now: 4.5))
        let suite = "switcher-test-" + UUID().uuidString
        let switcherDefaults = UserDefaults(suiteName: suite)!
        defer { switcherDefaults.removePersistentDomain(forName: suite) }
        let switcher = AppSwitcher(defaults: switcherDefaults, start: false)
        precondition(switcher.holdDelay == 0.45)
        switcher.holdDelay = 5
        precondition(AppSwitcher(defaults: switcherDefaults, start: false).holdDelay == 5)
        var slowHold = OptionHoldState()
        precondition(!slowHold.visible(optionOnly: true, now: 10, delay: switcher.holdDelay))
        precondition(!slowHold.visible(optionOnly: true, now: 14.99, delay: switcher.holdDelay))
        precondition(slowHold.visible(optionOnly: true, now: 15, delay: switcher.holdDelay))
        switcher.holdDelay = 6; precondition(switcher.holdDelay == 5)
        switcher.holdDelay = -1; precondition(switcher.holdDelay == 0.1)
        switcher.holdDelay = .nan; precondition(switcher.holdDelay == 0.45)
        print("PASS: Option hold delay default, persistence, five-second boundary and invalid input")
        switcher.panelEnabled = false
        let fixtureApp = SwitcherApp(id: "test.fixture", name: "Test", path: "/missing.app")
        let bindingKey = ClipboardShortcut(keyCode: 11, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), label: "⌃⌥⇧⌘B")
        try switcher.configure(fixtureApp, shortcut: bindingKey, show: true)
        try switcher.setVisibility(fixtureApp, show: false)
        precondition(switcher.bindings[fixtureApp.id]?.shortcut == bindingKey)
        let restoredSwitcher = AppSwitcher(defaults: switcherDefaults, start: false)
        precondition(restoredSwitcher.bindings == switcher.bindings && !restoredSwitcher.panelEnabled)
        do { try switcher.configure(fixtureApp, shortcut: testKey, show: false); preconditionFailure("Conflict must fail") } catch {}
        precondition(switcher.bindings[fixtureApp.id]?.shortcut == bindingKey)
        do { try switcher.configure(SwitcherApp(id: "other", name: "Other", path: "/other.app"), shortcut: bindingKey, show: false); preconditionFailure("Duplicate must fail") } catch {}
        try switcher.setVisibility(fixtureApp, show: true)
        let appIndex = AppSearchIndex(source: "微信\n/Applications/微信.app")
        for query in ["微信", "weixin", "WEIX", "wx", "wei xin", "ｗｘ", "Applications wx"] {
            precondition(appIndex.matches(query), "App search must match \(query)")
        }
        precondition(!appIndex.matches("notepad"))
        precondition(!appIndex.matches("wx missing"))
        precondition(SwitcherApp(id: "classic", name: "ChatGPT", path: "/Applications/ChatGPT Classic.app").displayName == "ChatGPT Classic")
        precondition(SwitcherApp(id: "current", name: "ChatGPT", path: "/Applications/ChatGPT.app").displayName == "ChatGPT")
        print("PASS: app pinyin, initials, mixed-token search and distinct edition names")
        try switcher.setAlias(fixtureApp, alias: "  工作助手  ")
        precondition(switcher.displayName(for: fixtureApp) == "工作助手")
        precondition(AppSearchIndex(source: switcher.displayName(for: fixtureApp)).matches("gzzs"))
        precondition(AppSwitcher(defaults: switcherDefaults, start: false).displayName(for: fixtureApp) == "工作助手")
        try switcher.configure(fixtureApp, shortcut: bindingKey, show: true)
        precondition(switcher.bindings[fixtureApp.id]?.alias == "工作助手")
        let aliasPanel = switcher.makePanel()
        precondition(aliasPanel.contentView!.subviews.compactMap { $0 as? SwitcherIconButton }.first?.title == "工作助手")
        aliasPanel.close()
        try switcher.setAlias(fixtureApp, alias: " ")
        precondition(switcher.displayName(for: fixtureApp) == fixtureApp.displayName)
        let legacy = Data("{\"path\":\"/test.app\",\"name\":\"Test\",\"showInPanel\":false}".utf8)
        let legacyBinding = try JSONDecoder().decode(SwitcherBinding.self, from: legacy)
        precondition(legacyBinding.alias == nil)
        print("PASS: app aliases persist, survive hotkey changes, display in panel, support pinyin and clear safely")
        let extraApp = SwitcherApp(id: "test.alpha", name: "Alpha", path: "/System/Applications/Contacts.app")
        let unconfiguredApp = SwitcherApp(id: "test.aaa", name: "AAA", path: "/missing.app")
        try switcher.setVisibility(extraApp, show: true)
        precondition(switcher.orderedApps([unconfiguredApp, fixtureApp, extraApp]).map(\.id) == [extraApp.id, fixtureApp.id, unconfiguredApp.id])
        switcher.moveConfigured(fixtureApp.id, offset: -1)
        precondition(switcher.orderedApps([unconfiguredApp, extraApp, fixtureApp]).map(\.id) == [fixtureApp.id, extraApp.id, unconfiguredApp.id])
        precondition(AppSwitcher(defaults: switcherDefaults, start: false).panelItems.map(\.id) == [fixtureApp.id, extraApp.id])
        try switcher.setVisibility(fixtureApp, show: false)
        precondition(switcher.orderedApps([extraApp, fixtureApp]).first?.id == fixtureApp.id)
        precondition(switcher.panelItems.map(\.id) == [extraApp.id])
        try switcher.setVisibility(fixtureApp, show: true)
        let hintPanel = switcher.makePanel()
        precondition(hintPanel.styleMask.contains(.nonactivatingPanel))
        precondition(hintPanel.frame.width > hintPanel.frame.height)
        precondition(!hintPanel.contentView!.subviews.contains { $0 is NSScrollView })
        let iconButtons = hintPanel.contentView!.subviews.compactMap { $0 as? SwitcherIconButton }
        precondition(iconButtons.map { $0.cell?.representedObject as? String } == [fixtureApp.id, extraApp.id])
        precondition(iconButtons.first?.shortcutText == bindingKey.label)
        let preview = hintPanel.contentView!
        preview.layoutSubtreeIfNeeded(); preview.displayIfNeeded()
        let switcherBitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
        preview.cacheDisplay(in: preview.bounds, to: switcherBitmap)
        try switcherBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/switcher-panel.png"))
        print("PASS: configured-first ordering, persistent reordering, panel filtering and horizontal icon layout")
        hintPanel.close()
        let crowdedDefaults = UserDefaults(suiteName: "switcher-layout-" + UUID().uuidString)!
        let crowded = AppSwitcher(defaults: crowdedDefaults, start: false)
        for index in 0..<30 {
            try crowded.setVisibility(SwitcherApp(id: "layout.\(index)", name: "App \(index)", path: "/System/Applications/Contacts.app"), show: true)
        }
        for screenWidth: CGFloat in [800, 1440, 2560] {
            let fitted = crowded.makePanel(availableWidth: screenWidth)
            let buttons = fitted.contentView!.subviews.compactMap { $0 as? SwitcherIconButton }
            precondition(buttons.count == 30 && fitted.frame.width <= screenWidth - 64)
            precondition(buttons.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= fitted.frame.width && $0.frame.maxY <= fitted.frame.height })
            precondition(buttons.first!.frame.width < 108)
            precondition(!fitted.contentView!.subviews.contains { $0 is NSScrollView })
            fitted.close()
        }
        print("PASS: 30 apps fit 800/1440/2560-point screens without scrolling")
        let savedBindings = switcher.bindings
        switcher.setFeatureEnabled(false)
        precondition(!switcher.featureEnabled && !switcher.containsShortcut(bindingKey))
        precondition(switcher.bindings == savedBindings)
        switcher.setFeatureEnabled(true)
        precondition(switcher.containsShortcut(bindingKey) && switcher.bindings == savedBindings)
        try switcher.configure(fixtureApp, shortcut: nil, show: false)
        precondition(switcher.bindings[fixtureApp.id]?.shortcut == nil)
        print("PASS: app hotkey routing, hold delay/release/suppression, persistence, independent visibility, conflict preservation and clear")
        try String(panel.window!.windowNumber).write(toFile: ".build/clipboard-window-id", atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard let window = panel.window, let view = window.contentView else { fatalError() }
        precondition(!window.isOpaque && window.backgroundColor == .clear)
        precondition(view.layer?.cornerRadius == 20 && view.layer?.masksToBounds == true)
        let motionProbe = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        motionProbe.wantsLayer = true
        ClipboardMotion.reducedMotionOverride = false
        ClipboardMotion.pulse(motionProbe)
        ClipboardMotion.fade(motionProbe)
        precondition(motionProbe.layer?.animation(forKey: "press") != nil)
        precondition(motionProbe.layer?.animation(forKey: "reveal") != nil)
        motionProbe.layer?.removeAllAnimations()
        ClipboardMotion.reducedMotionOverride = true
        ClipboardMotion.pulse(motionProbe)
        ClipboardMotion.fade(motionProbe)
        precondition(motionProbe.layer?.animationKeys()?.isEmpty ?? true)
        ClipboardMotion.reducedMotionOverride = nil
        print("PASS: transparent window, rounded clipped surface, finite motion and reduced-motion suppression")
        func snapshot(_ name: String, width: CGFloat) throws {
            window.setContentSize(NSSize(width: width, height: 350))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/" + name + ".png"))
        }
        try snapshot("clipboard-wide", width: 1050)
        try snapshot("clipboard-narrow", width: 680)
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
        precondition(allViews(view).compactMap { $0 as? NSPopUpButton }.allSatisfy { $0.identifier?.rawValue == "clipboard-groups" }, "List must only contain the group picker")
        precondition(!allViews(view).compactMap { $0 as? NSButton }.contains { $0.title.contains("清空") || $0.title.contains("记录") })
        let filter = allViews(view).compactMap { $0 as? NSSegmentedControl }.first!
        precondition(window.firstResponder is NSTextView, "Opening the panel must focus search")
        let editor = window.firstResponder as! NSTextView
        editor.setMarkedText("fangshi", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(panel.isComposingSearchText, "IME candidate confirmation must bypass clipboard shortcuts")
        editor.unmarkText()
        precondition(!panel.isComposingSearchText)
        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))

        editor.insertText("设计", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        let input = allViews(view).compactMap { $0 as? NSSearchField }.first!
        precondition(input.stringValue == "设计", "Typing immediately after opening must search")
        let searchScroll = allViews(view).compactMap { $0 as? ClipboardHorizontalScrollView }.first!
        let searchCard = searchScroll.documentView!.subviews.first!
        input.stringValue = "设计说"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        precondition(searchScroll.documentView!.subviews.first === searchCard, "Unchanged search result must reuse its card")
        precondition(searchCard.layer?.animation(forKey: "reveal") == nil, "Typing must not restart card opacity")
        input.stringValue = "不存在"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        input.stringValue = "设计"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        precondition(searchScroll.documentView!.subviews.first?.layer?.animation(forKey: "reveal") == nil)
        let matchLabel = allViews(searchScroll.documentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "search-match" }!
        precondition(matchLabel.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        input.stringValue = "sheji"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        precondition(matchLabel.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        input.stringValue = "shuoming"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        precondition(matchLabel.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        precondition(matchLabel.attributedStringValue.attribute(.backgroundColor, at: 2, effectiveRange: nil) != nil)
        print("PASS: IME marked-text guard and live Chinese/pinyin highlights without card recreation")
        print("PASS: search card reuse and no repeated reveal on changed results")
        input.stringValue = ""
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
        let fileID = store.entries.first!.id
        let pin = allViews(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == fileID.uuidString }!
        pin.performClick(nil)
        precondition(store.entries.first { $0.id == fileID }!.isPinned)
        filter.selectedSegment = 1
        app.sendAction(filter.action!, to: filter.target, from: filter)
        precondition(!allViews(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "developer.apple.com" })
        precondition(allViews(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "设计说明.md" })
        try snapshot("clipboard-pinned", width: 1050)
        filter.selectedSegment = 0
        app.sendAction(filter.action!, to: filter.target, from: filter)
        try snapshot("clipboard-wide", width: 1050)
        try snapshot("clipboard-narrow", width: 680)
        filter.selectedSegment = 3
        app.sendAction(filter.action!, to: filter.target, from: filter)
        precondition(allViews(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "developer.apple.com" })
        precondition(!allViews(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "设计说明.md" })
        filter.selectedSegment = 0
        app.sendAction(filter.action!, to: filter.target, from: filter)
        let permissionSuite = "permission-check-" + UUID().uuidString
        let permissionDefaults = UserDefaults(suiteName: permissionSuite)!
        defer { permissionDefaults.removePersistentDomain(forName: permissionSuite) }
        var trusted = false
        var prompts = 0
        let permissionSettings = ClipboardSettingsWindow(store: store, defaults: permissionDefaults,
            isTrusted: { trusted }, requestTrust: { prompts += 1 })
        let pasteToggle = allViews(permissionSettings.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title.contains("直接粘贴") }!
        pasteToggle.performClick(nil)
        precondition(prompts == 1)
        precondition(permissionDefaults.bool(forKey: "clipboardDirectPaste"), "Permission request must preserve the user's enable intent")
        trusted = true
        permissionSettings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        precondition(pasteToggle.state == .on, "Returning after granting permission must enable the switch")
        pasteToggle.performClick(nil)
        permissionSettings.refresh()
        precondition(!permissionDefaults.bool(forKey: "clipboardDirectPaste") && pasteToggle.state == .off)
        print("PASS: permission grant return, enable intent and explicit disable")
        let settings = ClipboardSettingsWindow(store: store)
        settings.present()
        let suiteName = "shortcut-check-" + UUID().uuidString
        let shortcutDefaults = UserDefaults(suiteName: suiteName)!
        defer { shortcutDefaults.removePersistentDomain(forName: suiteName) }
        settings.onShortcutChange = { value in
            guard shortcut.register(value) else { return false }
            value.save(defaults: shortcutDefaults)
            return true
        }
        let settingsView = settings.window!.contentView!
        settingsView.layoutSubtreeIfNeeded()
        let recorder = allViews(settingsView).compactMap { $0 as? NSButton }.first { $0.title.contains("点击修改") }!
        recorder.performClick(nil)
        let customEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control, .option], timestamp: 0,
            windowNumber: settings.window!.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        precondition(settings.captureShortcut(customEvent))
        let custom = ClipboardShortcut.saved(defaults: shortcutDefaults)
        precondition(custom.keyCode == 38 && shortcut.current == custom)
        recorder.performClick(nil)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: settings.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        precondition(!settings.captureShortcut(escape))
        precondition(ClipboardShortcut.saved(defaults: shortcutDefaults) == custom)
        let conflict = GlobalClipboardShortcut()
        let reserved = ClipboardShortcut(keyCode: 40, modifiers: UInt32(cmdKey | controlKey | optionKey), label: "⌃⌥⌘K")
        if conflict.register(reserved) {
            withExtendedLifetime(conflict) {
                precondition(!shortcut.register(reserved))
                precondition(shortcut.current == custom, "Conflict must preserve active registration")
            }
        }
        settings.onShortcutChange = { _ in false }
        recorder.performClick(nil)
        precondition(!settings.captureShortcut(customEvent))
        precondition(ClipboardShortcut.saved(defaults: shortcutDefaults) == custom)
        let plainEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: settings.window!.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        precondition(ClipboardShortcut.from(plainEvent) == nil)
        settings.onShortcutChange = { value in
            guard shortcut.register(value) else { return false }
            value.save(defaults: shortcutDefaults); return true
        }
        let reset = allViews(settingsView).compactMap { $0 as? NSButton }.first { $0.title == "恢复默认" }!
        reset.performClick(nil)
        if shortcut.current == .defaultValue { precondition(ClipboardShortcut.saved(defaults: shortcutDefaults) == .defaultValue) }
        else { precondition(ClipboardShortcut.saved(defaults: shortcutDefaults) == custom) }
        print("PASS: shortcut recording, persistence, cancel, modifier validation, conflict preservation and reset handling")
        let days = allViews(settingsView).compactMap { $0 as? NSPopUpButton }.first!
        days.selectItem(at: 1)
        app.sendAction(days.action!, to: days.target, from: days)
        precondition(store.retentionDays == 30)
        let restored = ClipboardStore(url: root.appendingPathComponent("history.json"), pasteboard: board)
        precondition(restored.retentionDays == 30)
        let recordToggle = allViews(settingsView).compactMap { $0 as? NSButton }.first { $0.title == "记录新的剪贴板内容" }!
        recordToggle.performClick(nil)
        precondition(!store.enabled)
        recordToggle.performClick(nil)
        precondition(store.enabled)
        store.stop()
        settingsView.displayIfNeeded()
        let settingsImage = settingsView.bitmapImageRepForCachingDisplay(in: settingsView.bounds)!
        settingsView.cacheDisplay(in: settingsView.bounds, to: settingsImage)
        try settingsImage.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/clipboard-settings.png"))
        settings.close()
        let search = allViews(view).compactMap { $0 as? NSSearchField }.first!
        search.stringValue = "不存在的词"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(allViews(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("没有匹配的历史") })
        search.stringValue = ""
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        if CommandLine.arguments.contains("--inspect") { try await Task.sleep(nanoseconds: 90_000_000_000) }
        let copy = allViews(view).compactMap { $0 as? NSButton }.first { $0.title == "复制所选" }!
        copy.performClick(nil)
        precondition(!window.isVisible)
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(urls?.first?.path == file.path)
        store.onChange = nil
        for index in 0..<60 {
            board.clearContents(); board.setString("lazy fixture \(index)", forType: .string); store.poll()
        }
        panel.present()
        window.setContentSize(NSSize(width: 680, height: 350))
        view.layoutSubtreeIfNeeded()
        search.stringValue = "lazy fixture"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let strip = allViews(view).compactMap { $0 as? ClipboardHorizontalScrollView }.first!
        precondition(!strip.hasHorizontalScroller && !strip.hasVerticalScroller)
        let document = strip.documentView!
        precondition(document.frame.width == 60 * 234)
        precondition(document.subviews.count <= 6, "Only viewport plus overscan cards should be loaded")
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
        strip.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        precondition(strip.contentView.bounds.minX > 0, "Vertical mouse wheel must move horizontally")
        strip.contentView.scroll(to: NSPoint(x: document.frame.width - strip.contentSize.width, y: 0))
        strip.reflectScrolledClipView(strip.contentView)
        precondition(document.subviews.count <= 6)
        precondition(document.subviews.contains { $0.identifier?.rawValue == "59" }, "Last item must load without paging")
        precondition(!document.subviews.contains { $0.identifier?.rawValue == "0" }, "Offscreen cards must be released")
        try snapshot("clipboard-lazy-end", width: 680)
        search.stringValue = "lazy fixture 59"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(strip.contentView.bounds.minX == 0)
        precondition(document.subviews.count == 1)
        let card = document.subviews.first!
        for point in [NSPoint(x: 100, y: 110), NSPoint(x: 100, y: 195), NSPoint(x: 100, y: 25)] {
            let hit = document.hitTest(card.convert(point, to: document))
            precondition(hit === card, "Card body, title and blank area must route clicks to the card")
        }
        let pinControl = allViews(card).compactMap { $0 as? NSButton }.first!
        let pinHit = document.hitTest(pinControl.convert(NSPoint(x: 16, y: 16), to: document))
        precondition(pinHit === pinControl, "Pin must retain independent hit testing")
        let clickPoint = card.convert(NSPoint(x: 100, y: 110), to: nil)
        let single = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        card.mouseDown(with: single)
        precondition(document.subviews.first === card, "Selection must preserve the view for the second click")
        let double = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint, modifierFlags: [], timestamp: 0.1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 1)!
        card.mouseDown(with: double)
        precondition(!window.isVisible && board.string(forType: .string) == "lazy fixture 59")
        print("PASS: whole-card hit testing, independent pin and double-click copy")
        panel.present()
        let beforeDelete = store.entries.count
        let backspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        precondition(!panel.handleDeleteKey(backspace), "Search editing must keep Backspace")
        precondition(store.entries.count == beforeDelete)
        window.makeFirstResponder(document)
        precondition(panel.handleDeleteKey(backspace))
        precondition(store.entries.count == beforeDelete - 1)
        precondition(!store.entries.contains { $0.text == "lazy fixture 59" })
        let repeatDelete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0.1,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 51)!
        search.stringValue = "lazy fixture"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(panel.handleDeleteKey(repeatDelete))
        precondition(store.entries.count == beforeDelete - 1, "Key repeat must not erase further entries")
        print("PASS: hidden scrollbars, selected Backspace deletion, search guard and repeat guard")
        panel.undoDeletion()
        precondition(store.entries.count == beforeDelete)
        let restoredID = store.entries.first { $0.text == "lazy fixture 59" }!.id
        try store.setOrganization(restoredID, alias: "常用命令", group: "开发")
        panel.refresh()
        let groups = allViews(view).compactMap { $0 as? NSPopUpButton }.first!
        groups.selectItem(withTitle: "开发")
        app.sendAction(groups.action!, to: groups.target, from: groups)
        precondition(document.subviews.count == 1)
        precondition(allViews(document).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "常用命令" })
        search.stringValue = "cym l"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(document.subviews.count == 1)
        try snapshot("clipboard-organized", width: 680)
        print("PASS: undo action, group picker and alias rendering/search")
        panel.close()
        print("PASS: wheel horizontal scrolling, continuous 60-item range, bounded lazy cards, eviction and search reset")
        let backgroundMenu = NSMenu()
        let actionTarget = SettingsActionProbe()
        for id in ["display-a", "display-b"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.representedObject = id
            let submenu = NSMenu(); submenu.autoenablesItems = false
            let choose = NSMenuItem(title: "Choose fixture", action: #selector(SettingsActionProbe.choose(_:)), keyEquivalent: "")
            choose.target = actionTarget; choose.representedObject = id
            submenu.addItem(choose)
            for index in 0..<20 {
                let extra = NSMenuItem(title: "Option \(index)", action: #selector(SettingsActionProbe.choose(_:)), keyEquivalent: "")
                extra.target = actionTarget; extra.representedObject = id
                submenu.addItem(extra)
            }
            item.submenu = submenu; backgroundMenu.addItem(item)
        }
        let preferences = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferences.isEnabled = true
        preferences.identifier = NSUserInterfaceItemIdentifier("wallpaperPreferences")
        let preferencesMenu = NSMenu(); preferencesMenu.autoenablesItems = false
        let globalOption = NSMenuItem(title: "Original fixture", action: #selector(SettingsActionProbe.choose(_:)), keyEquivalent: "")
        globalOption.target = actionTarget; globalOption.representedObject = "all-displays"
        globalOption.state = .on
        for title in ["低耗 · 1080p / 30 fps", "均衡 · 1440p / 30 fps"] {
            let option = NSMenuItem(title: title, action: #selector(SettingsActionProbe.choose(_:)), keyEquivalent: "")
            option.target = actionTarget; option.representedObject = "all-displays"
            preferencesMenu.addItem(option)
        }
        preferencesMenu.addItem(globalOption)
        preferencesMenu.addItem(.separator())
        for title in ["低内存循环（接缝可能短暂停顿）", "无缝循环（预加载下一轮）"] {
            let option = NSMenuItem(title: title, action: #selector(SettingsActionProbe.choose(_:)), keyEquivalent: "")
            option.target = actionTarget; option.representedObject = "all-displays"
            preferencesMenu.addItem(option)
        }
        preferencesMenu.addItem(.separator())
        let pauseOption = NSMenuItem(title: "桌面被遮挡时自动暂停", action: #selector(SettingsActionProbe.choose(_:)), keyEquivalent: "")
        pauseOption.target = actionTarget; pauseOption.representedObject = "all-displays"
        preferencesMenu.addItem(pauseOption)
        preferences.submenu = preferencesMenu; backgroundMenu.addItem(preferences)
        var loginState = SMAppService.Status.notRegistered
        let loginAccess = LoginItemAccess(status: { loginState }, register: { loginState = .enabled }, unregister: { loginState = .notRegistered })
        let unified = ClipboardSettingsWindow(store: store, defaults: switcherDefaults, loginAccess: loginAccess)
        unified.configureUnified(backgroundMenu: backgroundMenu, appSwitcher: switcher)
        unified.present()
        let unifiedView = unified.window!.contentView!
        let tabs = allViews(unifiedView).compactMap { $0 as? NSTabView }.first!
        precondition(tabs.numberOfTabViewItems == 4)
        precondition(ToolFeature.allCases.allSatisfy { $0.isEnabled(in: switcherDefaults) })
        var featureChanges = 0
        unified.onFeatureChange = { feature, enabled in
            featureChanges += 1
            precondition(feature.isEnabled(in: switcherDefaults) == enabled)
        }
        let featureButtons = allViews(tabs.tabViewItems[0].view!).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("toolEnabled.") == true }
        precondition(featureButtons.count == 3)
        for button in featureButtons { button.performClick(nil) }
        precondition(tabs.numberOfTabViewItems == 1 && featureChanges == 3)
        precondition(ToolFeature.allCases.allSatisfy { !$0.isEnabled(in: switcherDefaults) })
        unified.selectSection("apps")
        precondition(tabs.selectedTabViewItem?.identifier as? String == "general")
        for button in featureButtons { button.performClick(nil) }
        precondition(tabs.numberOfTabViewItems == 4 && featureChanges == 6)
        print("PASS: default-on feature switches persist, hide settings and restore sections")
        func settingsSnapshot(_ name: String) throws {
            unifiedView.layoutSubtreeIfNeeded(); unifiedView.displayIfNeeded()
            let bitmap = unifiedView.bitmapImageRepForCachingDisplay(in: unifiedView.bounds)!
            unifiedView.cacheDisplay(in: unifiedView.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/" + name + ".png"))
        }
        unified.selectSection("apps")
        // AppKit modal checks stop the command-line async main runloop; keep this final UI phase synchronous.
        let switcherView = allViews(tabs.selectedTabViewItem!.view!).compactMap { $0 as? AppSwitcherSettingsView }.first!
        switcherView.applyInventory(AppSwitcher.discover())
        let appsTable = allViews(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSTableView }.first!
        precondition(appsTable.numberOfRows > 1)
        try settingsSnapshot("settings-app-switcher")
        unified.selectSection("general")
        let loginButton = allViews(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSButton }.first { $0.title == "登录 Mac 时自动启动" }!
        loginButton.performClick(nil); precondition(loginState == .enabled && loginButton.state == .on)
        loginButton.performClick(nil); precondition(loginState == .notRegistered && loginButton.state == .off)
        loginState = .requiresApproval
        unified.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        precondition(loginButton.state == .mixed)
        loginState = .notRegistered
        unified.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        try settingsSnapshot("settings-general")
        unified.selectSection("clipboard"); try settingsSnapshot("settings-clipboard")
        unified.selectSection("wallpaper")
        let backgroundView = tabs.selectedTabViewItem!.view!
        precondition(allViews(backgroundView).compactMap { $0 as? NSPopUpButton }.isEmpty)
        let backgroundButtons = allViews(backgroundView).compactMap { $0 as? NSButton }
        precondition(!backgroundButtons.contains { $0.title == "Choose fixture" })
        let globalButton = backgroundButtons.first { $0.title == "✓ Original fixture" }!
        precondition(globalButton.isEnabled)
        let feedback = globalButton as! SettingsFeedbackButton
        let hoverEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: unified.window!.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let restingColor = feedback.layer!.backgroundColor!
        feedback.mouseEntered(with: hoverEvent)
        precondition(feedback.hovered && feedback.layer!.backgroundColor! != restingColor)
        feedback.highlight(true)
        let pressedColor = feedback.layer!.backgroundColor!
        feedback.highlight(false)
        precondition(feedback.layer!.backgroundColor! != pressedColor)
        feedback.mouseExited(with: hoverEvent)
        precondition(!feedback.hovered && feedback.layer!.backgroundColor! == restingColor)
        backgroundView.layoutSubtreeIfNeeded()
        let stack = allViews(backgroundView).compactMap { $0 as? NSStackView }.first!
        precondition(abs(stack.frame.maxY - (backgroundView.bounds.maxY - 24)) < 2, "Background settings must be top aligned")
        precondition(stack.frame.minY >= 0, "Background settings must fit in the page")
        globalButton.performClick(nil)
        precondition(actionTarget.lastDisplay == "all-displays")
        try settingsSnapshot("settings-wallpaper")
        unified.selectSection("general")
        var languageChangeNotified = false
        unified.onLanguageChange = { languageChangeNotified = true }
        let languageSelector = allViews(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSPopUpButton }.first!
        languageSelector.selectItem(at: 2)
        app.sendAction(languageSelector.action!, to: languageSelector.target, from: languageSelector)
        precondition(languageChangeNotified && AppLanguage.selection == "en")
        unified.close()
        AppLanguage.selection = "en"
        precondition(AppLanguage.text("设置") == "Settings")
        let englishSettings = ClipboardSettingsWindow(store: store)
        englishSettings.configureUnified(backgroundMenu: backgroundMenu)
        englishSettings.present()
        precondition(englishSettings.window!.title == "Settings · Light Tools")
        englishSettings.selectSection("clipboard")
        let englishView = englishSettings.window!.contentView!
        precondition(allViews(englishView).compactMap { $0 as? NSButton }.contains { $0.title == "Record new clipboard content" })
        englishView.layoutSubtreeIfNeeded(); englishView.displayIfNeeded()
        let englishBitmap = englishView.bitmapImageRepForCachingDisplay(in: englishView.bounds)!
        englishView.cacheDisplay(in: englishView.bounds, to: englishBitmap)
        try englishBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/settings-english.png"))
        englishSettings.close(); AppLanguage.selection = "zh-Hans"
        print("PASS: unified settings tabs, global preferences only, action routing and English controls")
        print("PASS: immediate typing search, pin action/filter, separate settings, retention persistence, layouts and file copy")
    }
}

@MainActor
final class SettingsActionProbe: NSObject {
    var lastDisplay: String?
    @objc func choose(_ sender: NSMenuItem) { lastDisplay = sender.representedObject as? String }
}
