import AppKit
import Carbon
import QuartzCore

struct ClipboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static let defaultValue = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘V")
    var isValid: Bool {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        return keyCode < 128 && modifiers & ~allowed == 0 && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 && !label.isEmpty && label.count <= 30
    }
    static func saved(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "clipboardShortcut"), let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return .defaultValue }
        return value
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "clipboardShortcut") }
    }
    static func from(_ event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
              "abcdefghijklmnopqrstuvwxyz0123456789 ".contains(key) || [123, 124, 125, 126].contains(Int(event.keyCode)) else { return nil }
        var modifiers: UInt32 = 0
        var label = ""
        for (flag, carbon, glyph): (NSEvent.ModifierFlags, Int, String) in [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { modifiers |= UInt32(carbon); label += glyph }
        }
        return Self(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + ([123: "←", 124: "→", 125: "↓", 126: "↑"][Int(event.keyCode)] ?? (key == " " ? "Space" : key.uppercased())))
    }
}

@MainActor
final class GlobalClipboardShortcut {
    private static var nextID: UInt32 = 0
    private static let instances = NSHashTable<GlobalClipboardShortcut>.weakObjects()
    private(set) static var isRecording = false
    static func setRecording(_ recording: Bool) {
        guard isRecording != recording else { return }
        isRecording = recording
        for item in instances.allObjects {
            if recording {
                if let key = item.hotKey { UnregisterEventHotKey(key); item.hotKey = nil }
            } else if let value = item.current { _ = item.register(value) }
        }
    }
    let identifier: UInt32
    init() { Self.nextID += 1; identifier = Self.nextID; Self.instances.add(self) }
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var current: ClipboardShortcut?
    var action: (() -> Void)?
    func register(_ value: ClipboardShortcut = .saved()) -> Bool {
        guard value.isValid else { return false }
        if hotKey != nil, current?.keyCode == value.keyCode, current?.modifiers == value.modifiers { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<GlobalClipboardShortcut>.fromOpaque(context).takeUnretainedValue()
                var received = EventHotKeyID()
                guard let event,
                      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                      received.signature == 0x4c54534b, received.id == shortcut.identifier else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in if !GlobalClipboardShortcut.isRecording { shortcut.action?() } }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return false }
        }
        var replacement: EventHotKeyRef?
        guard RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x4c54534b, id: identifier),
                                  GetApplicationEventTarget(), 0, &replacement) == noErr else { return false }
        // Keep the old registration alive unless the new combination succeeds.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        current = value
        return true
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil; current = nil
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
enum ClipboardPasteDelivery {
    // Wait for activation rather than assuming every application focuses within 200 ms.
    static func deliver(target: pid_t, own: pid_t,
                        frontmost: () -> pid_t?, trusted: () -> Bool,
                        alive: () -> Bool, send: () -> Void,
                        pause: () async -> Void = { try? await Task.sleep(nanoseconds: 50_000_000) }) async -> Bool {
        var focusedChecks = 0
        for _ in 0..<40 {
            await pause()
            guard trusted(), alive() else { return false }
            let front = frontmost()
            if front == target {
                focusedChecks += 1
                if focusedChecks >= 2 { send(); return true }
            } else {
                focusedChecks = 0
                // Never redirect a pending paste after the user switches to a third app.
                if let front, front != own { return false }
            }
        }
        return false
    }
}

@MainActor
final class ClipboardHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
        let limit = max(0, (documentView?.frame.width ?? 0) - contentSize.width)
        let x = min(limit, max(0, contentView.bounds.minX - delta * scale))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
enum ClipboardMotion {
    static var reducedMotionOverride: Bool?
    static var reduced: Bool { reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func fade(_ view: NSView, duration: Double = 0.16) {
        guard !reduced, let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.45; animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "reveal")
    }
    static func pulse(_ view: NSView) {
        guard !reduced, let layer = view.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 0.94, 1.025, 1]
        animation.keyTimes = [0, 0.25, 0.7, 1]
        animation.duration = 0.22
        layer.add(animation, forKey: "press")
    }
}

@MainActor
private final class ClipboardSurface: NSView {
    private let gradient = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.34, alpha: 0.65).cgColor
        gradient.colors = [NSColor(srgbRed: 0.105, green: 0.13, blue: 0.17, alpha: 1).cgColor,
                           NSColor(srgbRed: 0.085, green: 0.095, blue: 0.12, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1); gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.insertSublayer(gradient, at: 0)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

@MainActor
private final class ClipboardActionButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    private func hover(_ active: Bool) {
        guard isEnabled else { return }
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(ClipboardMotion.reduced)
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(active ? 0.10 : 0).cgColor
        layer?.cornerRadius = 8
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    override func mouseDown(with event: NSEvent) {
        wantsLayer = true; ClipboardMotion.pulse(self)
        super.mouseDown(with: event)
    }
}

@MainActor
private final class ClipboardCanvas: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class ClipboardCard: NSView {
    private var hoverTracking: NSTrackingArea?
    var isChosen = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    func style(hover: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(ClipboardMotion.reduced)
        CATransaction.setAnimationDuration(0.16)
        layer?.backgroundColor = (isChosen
            ? NSColor(srgbRed: 0.12, green: 0.19, blue: 0.27, alpha: 1)
            : NSColor(calibratedWhite: hover ? 0.205 : 0.15, alpha: 1)).cgColor
        layer?.borderWidth = isChosen ? 2 : 1
        layer?.borderColor = (isChosen ? NSColor.systemBlue : NSColor(calibratedWhite: hover ? 0.48 : 0.32, alpha: 1)).cgColor
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { style(hover: true) }
    override func mouseExited(with event: NSEvent) { style() }
    var choose: (() -> Void)?
    var copyItem: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Preview content belongs to the card interaction; only explicit buttons act independently.
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if view is NSButton { return view }
            candidate = view.superview
        }
        return self
    }
    override func accessibilityPerformPress() -> Bool { choose?(); copyItem?(); return true }
    override func mouseDown(with event: NSEvent) {
        choose?()
        ClipboardMotion.pulse(self)
        if event.clickCount > 1 { copyItem?() }
    }
}

@MainActor
private final class ClipboardListPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardWindow: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let store: ClipboardStore
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: [AppLanguage.text("历史"), AppLanguage.text("已固定"), AppLanguage.text("文字"), AppLanguage.text("链接"), AppLanguage.text("图片"), AppLanguage.text("文件")], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let scroll = ClipboardHorizontalScrollView()
    private let cards = ClipboardCanvas()
    private let copyButton = ClipboardActionButton()
    private let deleteButton = ClipboardActionButton()
    private let groupPicker = NSPopUpButton()
    private let organizeButton = ClipboardActionButton()
    private let undoButton = ClipboardActionButton()
    private var selectedGroup: String?
    private let pageLabel = NSTextField(labelWithString: "")
    private var results: [ClipboardEntry] = []
    private var selected: UUID?
    private var renderingCards = false
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        let window = ClipboardListPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 350),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = AppLanguage.text("轻工具 · 剪贴板列表")
        window.minSize = NSSize(width: 680, height: 330)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        let content = ClipboardSurface(frame: window.contentLayoutRect)
        window.contentView = content
        search.placeholderString = AppLanguage.text("搜索 / 拼音 / 首字母")
        search.setAccessibilityLabel(AppLanguage.text("搜索剪贴板历史"))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        filter.wantsLayer = true
        search.wantsLayer = true
        pageLabel.wantsLayer = true
        filter.selectedSegment = 0
        filter.target = self; filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel(AppLanguage.text("内容类型"))
        let settings = ClipboardActionButton(); configure(settings, title: "", action: #selector(openSettings))
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: AppLanguage.text("剪贴板设置"))
        settings.toolTip = AppLanguage.text("剪贴板设置")
        let dismiss = ClipboardActionButton(); configure(dismiss, title: "", action: #selector(dismissList))
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: AppLanguage.text("关闭列表"))
        let spacer = NSView()
        let top = NSStackView(views: [search, filter, spacer, settings, dismiss])
        top.orientation = .horizontal; top.spacing = 10
        configure(copyButton, title: AppLanguage.text("复制所选"), action: #selector(copySelected))
        configure(deleteButton, title: AppLanguage.text("删除"), action: #selector(deleteSelected))
        groupPicker.identifier = NSUserInterfaceItemIdentifier("clipboard-groups")
        groupPicker.setAccessibilityLabel(AppLanguage.text("剪贴板分组"))
        groupPicker.target = self; groupPicker.action = #selector(groupChanged)
        groupPicker.translatesAutoresizingMaskIntoConstraints = false
        groupPicker.widthAnchor.constraint(equalToConstant: 112).isActive = true
        configure(organizeButton, title: "", action: #selector(editOrganization))
        organizeButton.image = NSImage(systemSymbolName: "tag", accessibilityDescription: AppLanguage.text("分组与别名"))
        organizeButton.toolTip = AppLanguage.text("编辑所选项的分组与别名")
        configure(undoButton, title: "", action: #selector(undoDeletion))
        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: AppLanguage.text("撤销删除"))
        undoButton.toolTip = AppLanguage.text("撤销上次删除（⌘Z）")
        let bottom = NSStackView(views: [status, groupPicker, organizeButton, undoButton, copyButton, deleteButton, pageLabel])
        bottom.orientation = .horizontal; bottom.spacing = 8
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.documentView = cards
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            search.widthAnchor.constraint(equalToConstant: 190),
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    func present() {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let width = frame.width - 16
            window.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 8, width: width,
                                   height: min(350, frame.height - 16)), display: true)
        }
        refresh()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        if let surface = window.contentView { ClipboardMotion.fade(surface, duration: 0.22) }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if self.isComposingSearchText { return event }
                if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                   event.keyCode == 6, !(self.window?.firstResponder is NSTextView) {
                    self.undoDeletion(); return nil
                }
                if event.keyCode == 53 { self.close(); return nil }
                if event.modifierFlags.contains(.command), event.keyCode == 3 {
                    self.window?.makeFirstResponder(self.search); return nil
                }
                if event.modifierFlags.contains(.command), event.keyCode == 8, !(self.window?.firstResponder is NSTextView) {
                    self.performCopy(allowPaste: false); return nil
                }
                if event.modifierFlags.contains(.command), event.keyCode == 35 {
                    self.pinSelected(); return nil
                }
                if event.keyCode == 36 { self.copySelected(); return nil }
                // Option-arrows navigate while editing search; bare arrows navigate when cards have focus.
                if self.handleDeleteKey(event) { return nil }
                let editing = self.window?.firstResponder is NSTextView
                if (!editing || event.modifierFlags.contains(.option)), [123, 124].contains(event.keyCode) {
                    self.moveSelection(event.keyCode == 124 ? 1 : -1); return nil
                }
                return event
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        previousApp?.activate(options: [])
        onClose?()
    }
    var isComposingSearchText: Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
    private func updateHighlights(in view: NSView) {
        if let label = view as? NSTextField, label.identifier?.rawValue == "search-match" {
            let value = NSMutableAttributedString(attributedString: label.attributedStringValue)
            let whole = NSRange(location: 0, length: value.length)
            value.removeAttribute(.backgroundColor, range: whole)
            value.addAttribute(.foregroundColor, value: label.textColor ?? NSColor.labelColor, range: whole)
            for range in ClipboardSearchHighlight.ranges(in: value.string, query: search.stringValue) {
                value.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.32),
                                     .foregroundColor: NSColor.white], range: range)
            }
            label.attributedStringValue = value
        }
        for child in view.subviews { updateHighlights(in: child) }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { ClipboardMotion.fade(search, duration: 0.12) }
    func controlTextDidChange(_ obj: Notification) { cards.layer?.removeAnimation(forKey: "reveal"); selected = nil; scroll.contentView.scroll(to: .zero); refresh() }
    @objc private func filterChanged() { selected = nil; scroll.contentView.scroll(to: .zero); refresh(); ClipboardMotion.fade(cards); ClipboardMotion.pulse(filter) }
    func refresh() {
        let previousResults = results
        let groupChoices = Array(Set(store.groups + [selectedGroup].compactMap { $0 }.filter { !$0.isEmpty })).sorted()
        groupPicker.removeAllItems()
        groupPicker.addItems(withTitles: [AppLanguage.text("全部分组"), AppLanguage.text("未分组")] + groupChoices)
        if let selectedGroup { groupPicker.selectItem(at: selectedGroup.isEmpty ? 1 : (groupChoices.firstIndex(of: selectedGroup) ?? 0) + 2) }
        else { groupPicker.selectItem(at: 0) }
        for (index, group) in groupChoices.enumerated() { groupPicker.item(at: index + 2)?.representedObject = group }
        undoButton.isEnabled = store.canUndoDelete && store.error == nil
        results = store.search(search.stringValue).filter { entry in
            if let selectedGroup, (entry.group ?? "") != selectedGroup { return false }
            switch filter.selectedSegment {
            case 1: return entry.isPinned
            case 2: return entry.kind == .text && entry.linkURL == nil
            case 3: return entry.linkURL != nil
            case 4: return entry.kind == .image
            case 5: return entry.kind == .files
            default: return true
            }
        }
        if !results.contains(where: { $0.id == selected }) { selected = results.first?.id }
        copyButton.title = directPasteEnabled ? AppLanguage.text("粘贴所选") : AppLanguage.text("复制所选")
        copyButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil && store.error == nil
        organizeButton.isEnabled = deleteButton.isEnabled
        status.stringValue = store.error ?? store.notice ?? (store.enabled
            ? AppLanguage.text("直接输入搜索 · ⌥←→ 选择 · 回车复制 · ⌘P 固定 · ⌫ 删除")
            : AppLanguage.text("记录已暂停，可在设置中开启"))
        status.toolTip = status.stringValue
        renderingCards = true
        for view in cards.subviews {
            guard let card = view as? ClipboardCard,
                  let raw = card.identifier?.rawValue, let index = Int(raw),
                  previousResults.indices.contains(index), results.indices.contains(index),
                  previousResults[index] == results[index] else {
                view.removeFromSuperview()
                continue
            }
            card.isChosen = results[index].id == selected
            card.style()
            updateHighlights(in: card)
        }
        cards.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, CGFloat(results.count) * 234), height: max(238, scroll.contentSize.height))
        let limit = max(0, cards.frame.width - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: min(scroll.contentView.bounds.minX, limit), y: 0))
        renderingCards = false
        let countText = AppLanguage.text("\(results.count) 项")
        if pageLabel.stringValue != countText { pageLabel.stringValue = countText }
        renderVisibleCards()
    }
    @objc private func viewportChanged() { renderVisibleCards() }
    private func renderVisibleCards() {
        guard !renderingCards else { return }
        renderingCards = true
        defer { renderingCards = false }
        let bounds = scroll.contentView.bounds
        let cardHeight = max(232, bounds.height - 12)
        if let first = cards.subviews.first as? ClipboardCard, first.frame.height != cardHeight {
            cards.subviews.forEach { $0.removeFromSuperview() }
        }
        let start = max(0, Int(floor(bounds.minX / 234)) - 1)
        let end = min(results.count, max(start, Int(ceil(bounds.maxX / 234)) + 1))
        let visibleIndices = start..<max(start, end)
        for card in cards.subviews {
            if let raw = card.identifier?.rawValue, let index = Int(raw), visibleIndices.contains(index) { continue }
            card.removeFromSuperview()
        }
        let loaded = Set(cards.subviews.compactMap { $0.identifier?.rawValue }.compactMap(Int.init))
        if results.isEmpty {
            let text = NSTextField(wrappingLabelWithString: search.stringValue.isEmpty
                ? "\(store.enabled ? "复制一段文字、一张图片或一个文件，历史会出现在这里。" : "打开右上角设置，点击“开启记录”后开始保存。")"
                : AppLanguage.text("没有匹配的历史。试试其他关键词或切换内容类型。"))
            text.frame = NSRect(x: 16, y: 60, width: 560, height: 60)
            text.textColor = .secondaryLabelColor
            cards.addSubview(text)
        }
        for index in visibleIndices where !loaded.contains(index) {
            let entry = results[index]
            let card = ClipboardCard(frame: NSRect(x: CGFloat(index) * 234 + 3, y: 3, width: 220, height: cardHeight))
            card.identifier = NSUserInterfaceItemIdentifier(String(index))
            card.wantsLayer = true
            card.layer?.cornerRadius = 14
            card.layer?.cornerCurve = .continuous
            card.layer?.masksToBounds = true
            card.isChosen = selected == entry.id
            card.style()
            card.setAccessibilityElement(true)
            card.setAccessibilityRole(.button)
            card.setAccessibilityLabel("\(entry.typeTitle)，\(String(entry.title.prefix(100)))")
            card.toolTip = String(entry.title.prefix(1500))
            let header = NSView(frame: NSRect(x: 3, y: cardHeight - 54, width: 214, height: 51))
            header.wantsLayer = true
            let color: NSColor = entry.linkURL != nil ? NSColor(srgbRed: 0.08, green: 0.16, blue: 0.38, alpha: 1)
                : entry.kind == .image ? NSColor(srgbRed: 0.02, green: 0.48, blue: 0.31, alpha: 1)
                : entry.kind == .files ? NSColor(srgbRed: 0.22, green: 0.52, blue: 0.83, alpha: 1)
                : NSColor(srgbRed: 0.19, green: 0.43, blue: 0.88, alpha: 1)
            header.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
            let accent = NSView(frame: NSRect(x: 11, y: 47, width: 28, height: 3))
            accent.wantsLayer = true; accent.layer?.cornerRadius = 1.5
            accent.layer?.backgroundColor = color.cgColor
            header.addSubview(accent)
            let label = NSTextField(labelWithString: entry.alias ?? AppLanguage.text(entry.typeTitle))
            if entry.alias != nil { label.identifier = NSUserInterfaceItemIdentifier("search-match") }
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.frame = NSRect(x: 46, y: 27, width: 120, height: 18)
            header.addSubview(label)
            let time = NSTextField(labelWithString: (entry.group ?? (entry.isPinned ? AppLanguage.text("已固定") : "")) + (entry.group != nil || entry.isPinned ? " · " : "") + entry.relativeTime)
            time.font = .systemFont(ofSize: 11); time.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
            time.frame = NSRect(x: 46, y: 8, width: 120, height: 16)
            header.addSubview(time)
            let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 28, height: 28))
            if let bundle = entry.sourceBundleIdentifier,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                icon.image = NSWorkspace.shared.icon(forFile: appURL.path)
            } else {
                icon.image = NSImage(systemSymbolName: entry.kind == .image ? "photo" : entry.kind == .files ? "doc" : entry.linkURL != nil ? "link" : "text.alignleft", accessibilityDescription: nil)
                icon.contentTintColor = .white
            }
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.toolTip = entry.sourceAppName ?? AppLanguage.text("来源未记录")
            header.addSubview(icon)
            let pin = ClipboardActionButton(frame: NSRect(x: 175, y: 10, width: 32, height: 32))
            pin.bezelStyle = .regularSquare
            pin.isBordered = false
            pin.image = NSImage(systemSymbolName: entry.isPinned ? "pin.fill" : "pin", accessibilityDescription: entry.isPinned ? AppLanguage.text("取消固定") : AppLanguage.text("固定此项"))
            pin.contentTintColor = entry.isPinned ? .systemYellow : .secondaryLabelColor
            pin.toolTip = entry.isPinned ? AppLanguage.text("取消固定（恢复普通保留规则）") : AppLanguage.text("固定此项（不自动过期）")
            pin.setAccessibilityLabel(entry.isPinned ? AppLanguage.text("取消固定") : AppLanguage.text("固定此项"))
            pin.setAccessibilityValue(entry.isPinned ? AppLanguage.text("已固定") : AppLanguage.text("未固定"))
            pin.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
            pin.target = self; pin.action = #selector(pinCard(_:))
            header.addSubview(pin)
            card.addSubview(header)
            if entry.kind == .image, let thumbnail = store.thumbnail(for: entry) {
                let image = NSImageView(frame: NSRect(x: 8, y: 28, width: 204, height: cardHeight - 90))
                image.image = thumbnail; image.imageScaling = .scaleProportionallyUpOrDown
                card.addSubview(image)
            } else if let link = entry.linkURL {
                let symbol = NSImageView(frame: NSRect(x: 84, y: 100, width: 52, height: 52))
                symbol.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                symbol.contentTintColor = .systemBlue
                card.addSubview(symbol)
                let name = NSTextField(wrappingLabelWithString: link.host ?? entry.text)
                name.font = .systemFont(ofSize: 13, weight: .medium)
                name.frame = NSRect(x: 12, y: 38, width: 196, height: 48)
                name.identifier = NSUserInterfaceItemIdentifier("search-match")
                name.maximumNumberOfLines = 2
                card.addSubview(name)
            } else {
                if entry.kind == .files {
                    let image = NSImageView(frame: NSRect(x: 82, y: 110, width: 56, height: 56))
                    image.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
                    image.contentTintColor = .systemBlue
                    card.addSubview(image)
                }
                let text = NSTextField(wrappingLabelWithString: String(entry.title.prefix(500)))
                text.frame = NSRect(x: 12, y: 34, width: 196, height: entry.kind == .files ? 64 : cardHeight - 100)
                text.identifier = NSUserInterfaceItemIdentifier("search-match")
                text.font = .systemFont(ofSize: 12)
                text.maximumNumberOfLines = entry.kind == .files ? 3 : 8
                text.lineBreakMode = .byWordWrapping
                card.addSubview(text)
            }
            let metadata = NSTextField(labelWithString: AppLanguage.text(store.detail(for: entry)))
            if entry.kind == .files || entry.linkURL != nil { metadata.identifier = NSUserInterfaceItemIdentifier("search-match") }
            metadata.font = .systemFont(ofSize: 10); metadata.textColor = .secondaryLabelColor
            metadata.frame = NSRect(x: 12, y: 10, width: 174, height: 15)
            metadata.lineBreakMode = .byTruncatingMiddle
            card.addSubview(metadata)
            let number = NSTextField(labelWithString: "\(index + 1)")
            number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            number.textColor = .secondaryLabelColor
            number.frame = NSRect(x: 191, y: 10, width: 22, height: 15)
            card.addSubview(number)
            card.choose = { [weak self] in
                guard let self else { return }
                self.selected = entry.id
                self.window?.makeFirstResponder(self.cards)
                for view in self.cards.subviews {
                    guard let raw = view.identifier?.rawValue, let index = Int(raw), self.results.indices.contains(index) else { continue }
                    let active = self.results[index].id == self.selected
                    if let card = view as? ClipboardCard { card.isChosen = active; card.style() }
                }
            }
            card.copyItem = { [weak self] in self?.copySelected() }
            updateHighlights(in: card)
            cards.addSubview(card)
        }
    }
    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex(where: { $0.id == selected }) ?? 0
        let next = min(results.count - 1, max(0, index + delta))
        selected = results[next].id
        cards.scrollToVisible(NSRect(x: CGFloat(next) * 234, y: 0, width: 226, height: 238))
        refresh()
    }
    @objc private func copySelected() { performCopy(allowPaste: true) }
    private func performCopy(allowPaste: Bool) {
        guard let selected else { return }
        do {
            try store.copy(selected)
            let wantsPaste = allowPaste && UserDefaults.standard.bool(forKey: "clipboardDirectPaste")
            guard wantsPaste else { close(); return }
            guard AXIsProcessTrusted() else {
                showPasteFailure(AppLanguage.text("当前版本尚未获得辅助功能权限。请在系统设置中授权正在运行的轻工具；内容已复制，也可以返回目标输入框按 ⌘V。"))
                return
            }
            guard let target = previousApp, !target.isTerminated else {
                showPasteFailure(AppLanguage.text("没有找到呼出列表前的应用。请先点目标输入框，再用快捷键呼出剪贴板。内容已复制。"))
                return
            }
            close()
            target.activate(options: [])
            Task { @MainActor in
                let sent = await ClipboardPasteDelivery.deliver(
                    target: target.processIdentifier, own: ProcessInfo.processInfo.processIdentifier,
                    frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    trusted: { AXIsProcessTrusted() }, alive: { !target.isTerminated },
                    send: {
                        let source = CGEventSource(stateID: .combinedSessionState)
                        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
                        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
                        down?.flags = .maskCommand; up?.flags = .maskCommand
                        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
                    })
                if !sent {
                    self.showPasteFailure(AppLanguage.text("未能确认原应用已恢复焦点，或辅助功能权限不可用，因此没有发送粘贴。内容已复制，请在目标输入框按 ⌘V。"))
                }
            }
        }
        catch { showError(error) }
    }
    private func showPasteFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = AppLanguage.text("内容已复制，未自动粘贴")
        alert.informativeText = message
        alert.addButton(withTitle: AppLanguage.text("知道了"))
        alert.runModal()
    }
    private var directPasteEnabled: Bool { UserDefaults.standard.bool(forKey: "clipboardDirectPaste") && AXIsProcessTrusted() }
    @objc private func openSettings() { onSettings?() }
    @objc private func dismissList() { close() }

    @objc private func pinCard(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        togglePin(id)
    }
    @objc private func pinSelected() { if let selected { togglePin(selected) } }
    private func togglePin(_ id: UUID) {
        guard let entry = store.entries.first(where: { $0.id == id }) else { return }
        do {
            try store.setPinned(!entry.isPinned, for: id); refresh()
            if let index = results.firstIndex(where: { $0.id == id }),
               let card = cards.subviews.first(where: { $0.identifier?.rawValue == String(index) }) {
                ClipboardMotion.pulse(card)
            }
        }
        catch { showError(error) }
    }

    @objc private func groupChanged() {
        selectedGroup = groupPicker.indexOfSelectedItem == 0 ? nil : groupPicker.indexOfSelectedItem == 1 ? "" : groupPicker.selectedItem?.representedObject as? String
        selected = nil; scroll.contentView.scroll(to: .zero); refresh()
    }
    @objc private func editOrganization() {
        guard let id = selected, let entry = store.entries.first(where: { $0.id == id }) else { return }
        let alias = NSTextField(string: entry.alias ?? "")
        alias.placeholderString = AppLanguage.text("别名（可留空，不修改原内容）")
        let group = NSComboBox()
        group.addItems(withObjectValues: store.groups)
        group.stringValue = entry.group ?? ""
        group.placeholderString = AppLanguage.text("选择或输入新分组，留空取消分组")
        let form = NSStackView(views: [NSTextField(labelWithString: AppLanguage.text("别名")), alias,
            NSTextField(labelWithString: AppLanguage.text("分组（设置分组会固定此项）")), group])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 340, height: 112)
        alias.widthAnchor.constraint(equalToConstant: 340).isActive = true
        group.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let alert = NSAlert()
        alert.messageText = AppLanguage.text("分组与别名")
        alert.accessoryView = form
        alert.addButton(withTitle: AppLanguage.text("保存")); alert.addButton(withTitle: AppLanguage.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.setOrganization(id, alias: alias.stringValue, group: group.stringValue); refresh() }
        catch { showError(error) }
    }
    @objc func undoDeletion() {
        do {
            if let id = try store.undoDelete() {
                selected = id
                selectedGroup = nil; filter.selectedSegment = 0; search.stringValue = ""
                refresh()
                if let index = results.firstIndex(where: { $0.id == id }) {
                    cards.scrollToVisible(NSRect(x: CGFloat(index) * 234, y: 0, width: 226, height: 238))
                }
            }
        } catch { showError(error) }
    }

    @discardableResult func handleDeleteKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 51, event.window === window,
              !(window?.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        // Holding Backspace must not erase a run of history entries.
        if !event.isARepeat { deleteSelected() }
        return true
    }
    @objc private func deleteSelected() {
        guard let selected, store.error == nil else { return }
        let index = results.firstIndex(where: { $0.id == selected }) ?? 0
        let remaining = results.filter { $0.id != selected }
        do {
            try store.remove(selected)
            self.selected = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            refresh()
        } catch { showError(error) }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = AppLanguage.text("剪贴板操作未完成"); alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
