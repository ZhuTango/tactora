import AppKit

@MainActor
final class QuickActionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickActionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

@MainActor
struct QuickActionContext {
    let application: NSRunningApplication?
    let window: AXUIElement?
    let internalWindow: NSWindow?
}

@MainActor
final class QuickActionsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let search = NSSearchField()
    let table = NSTableView()
    private let feedback = NSTextField(labelWithString: "")
    private let history: QuickActionHistory
    private var commands: [QuickAction] = []
    private var appActions: [QuickAction] = []
    private(set) var results: [QuickAction] = []
    private var monitors: [Any] = []
    private var generation = 0
    private var executing = false
    private var scan: Task<Void, Never>?
    private var lastScan = Date.distantPast
    private(set) var context: QuickActionContext?
    var commandProvider: (() -> [QuickAction])?
    var onExecute: ((QuickAction, QuickActionContext, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onSettings: (() -> Void)?
    var configuredApps: (() -> [SwitcherApp])?

    init(defaults: UserDefaults = .standard) {
        history = QuickActionHistory(defaults: defaults)
        let panel = QuickActionsPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 462), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = AppLanguage.english ? "Quick Actions" : "快捷操作"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        panel.contentView = root
        search.placeholderString = AppLanguage.english ? "Search actions, apps, or paste content…" : "搜索操作、应用，或粘贴内容…"
        search.font = .systemFont(ofSize: 18)
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("quickActions.search")
        search.setAccessibilityLabel(AppLanguage.english ? "Search actions and apps" : "搜索操作与应用")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(executeSelected)
        table.setAccessibilityLabel(AppLanguage.english ? "Available actions" : "操作结果")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: AppLanguage.english ? "Quick Actions Settings" : "快捷操作设置")!, target: self, action: #selector(openSettings))
        settings.bezelStyle = .inline
        settings.toolTip = AppLanguage.english ? "Quick Actions Settings" : "快捷操作设置"
        let footer = NSStackView(views: [feedback, NSView(), settings])
        footer.spacing = 8
        for view in [search, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.heightAnchor.constraint(equalToConstant: 34),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 20)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func present() {
        guard let window else { return }
        if window.isVisible { dismiss(restoreFocus: true); return }
        let app = NSWorkspace.shared.frontmostApplication
        let internalWindow = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? NSApp.keyWindow : nil
        context = QuickActionContext(application: app, window: WindowManager.captureFocusedWindow(), internalWindow: internalWindow)
        generation += 1
        executing = false
        search.isEnabled = true
        search.stringValue = ""
        commands = commandProvider?() ?? []
        rebuild()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let width = min(600, area.width - 32)
            let height = min(110 + CGFloat(max(1, min(8, results.count))) * 44, area.height - 32)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2 + min(80, (area.height - height) / 2), width: width, height: height), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        installMonitors()
        refreshApps()
    }
    func dismiss(restoreFocus: Bool) {
        let previous = context
        generation += 1
        window?.orderOut(nil)
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        search.stringValue = ""
        results = []
        context = nil
        if restoreFocus {
            if let internalWindow = previous?.internalWindow { internalWindow.makeKeyAndOrderFront(nil) }
            else if let app = previous?.application, !app.isTerminated { app.activate(options: []) }
        }
    }
    override func close() { dismiss(restoreFocus: false); scan?.cancel() }
    func windowDidResignKey(_ notification: Notification) {
        if window?.isVisible == true, !executing { dismiss(restoreFocus: false) }
    }
    var isComposing: Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    private func installMonitors() {
        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.window, !self.isComposing else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { self.dismiss(restoreFocus: true); return nil }
            guard !self.executing else { return event }
            if flags.isEmpty {
                switch event.keyCode {
                case 125: self.moveSelection(1); return nil
                case 126: self.moveSelection(-1); return nil
                case 36, 76:
                    if self.window?.firstResponder === self.table || self.window?.firstResponder is NSTextView { self.executeSelected(); return nil }
                default: break
                }
            }
            return event
        }) { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.dismiss(restoreFocus: false) }) { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if let self, event.window !== self.window { self.dismiss(restoreFocus: false) }
            return event
        }) { monitors.append(token) }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !isComposing else { return }
        rebuild()
    }
    func rebuild(preservingSelection: Bool = false) {
        let selectedID = preservingSelection && results.indices.contains(table.selectedRow) ? results[table.selectedRow].id : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count <= TextProcessor.maximumBytes else {
            results = []; table.reloadData()
            feedback.stringValue = AppLanguage.english ? "Input exceeds 1 MB" : "输入超过 1 MB，请缩短内容"
            return
        }
        results = query.count > 256 ? [] : history.results(commands + (ToolFeature.apps.isEnabled() ? appActions : []), query: query)
        if !query.isEmpty {
            let mode = TextWorkbench.detect(query)
            if mode == .json || mode == .timestamp {
                let title = mode == .json ? (AppLanguage.english ? "Process JSON" : "处理 JSON") : (AppLanguage.english ? "Convert timestamp" : "转换时间戳")
                results.insert(QuickAction(id: "content.text", title: title, detail: AppLanguage.english ? "Open in Text Tools" : "在文本处理面板查看结果", symbol: "text.alignleft", destination: .text(search.stringValue)), at: 0)
            }
            if let minutes = Self.awakeMinutes(query) {
                results.insert(QuickAction(id: "awake.custom", title: AppLanguage.english ? "Keep awake for \(minutes) minutes" : "防休眠 \(minutes) 分钟", symbol: "sun.max", destination: .awake(minutes)), at: 0)
            }
        }
        table.reloadData()
        if !results.isEmpty {
            let selectedRow = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            table.scrollRowToVisible(selectedRow)
        }
        if let window, window.isVisible {
            let available = window.screen?.visibleFrame.height ?? 800
            let height = min(110 + CGFloat(max(1, min(8, results.count))) * 44, available - 32)
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
        }
        feedback.stringValue = results.isEmpty ? (AppLanguage.english ? "No matching actions" : "没有匹配的操作") : (AppLanguage.english ? "↑↓ Select  ·  Return Run  ·  Esc Close" : "↑↓ 选择  ·  回车执行  ·  Esc 关闭")
    }
    static func awakeMinutes(_ query: String) -> Int? {
        let pattern = #"^(?:防休眠|保持唤醒|awake)\s*(\d{1,5})\s*(?:分钟|min)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let range = Range(match.range(at: 1), in: query), let minutes = Int(query[range]),
              (1...KeepAwake.maximumMinutes).contains(minutes) else { return nil }
        return minutes
    }
    func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    @objc func executeSelected() {
        let row = table.selectedRow
        guard !isComposing, !executing, results.indices.contains(row), let context, let onExecute else { return }
        let action = results[row]
        let token = generation
        executing = true
        search.isEnabled = false
        onExecute(action, context) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.executing = false
            self.search.isEnabled = true
            switch result {
            case .success:
                if action.id != "content.text" && action.id != "awake.custom" { self.history.record(action.id) }
                self.dismiss(restoreFocus: false)
            case .failure(let error):
                self.feedback.stringValue = error.localizedDescription
                self.feedback.toolTip = error.localizedDescription
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.search)
            }
        }
    }
    @objc private func openSettings() { dismiss(restoreFocus: false); onSettings?() }
    @objc private func toggleFavorite(_ sender: NSButton) {
        guard results.indices.contains(sender.tag) else { return }
        let id = results[sender.tag].id
        history.toggleFavorite(id)
        rebuild()
        if let row = results.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(search)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { QuickActionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let action = results[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: action.detail.isEmpty ? [title] : [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let star = NSButton(image: NSImage(systemSymbolName: history.favorites.contains(action.id) ? "star.fill" : "star", accessibilityDescription: AppLanguage.english ? "Toggle favorite" : "切换收藏")!, target: self, action: #selector(toggleFavorite(_:)))
        star.bezelStyle = .inline
        star.tag = row
        star.setAccessibilityLabel((history.favorites.contains(action.id) ? "取消收藏 " : "收藏 ") + action.title)
        star.widthAnchor.constraint(equalToConstant: 28).isActive = true
        star.isHidden = action.id == "content.text" || action.id == "awake.custom"
        let content = NSStackView(views: [icon, labels, NSView(), star])
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        content.setAccessibilityLabel(action.title + " " + action.detail)
        return content
    }
    private func refreshApps() {
        guard scan == nil, Date().timeIntervalSince(lastScan) > 60 else { return }
        let configured = configuredApps?() ?? []
        scan = Task { [weak self] in
            let apps = await Task.detached(priority: .utility) { AppSwitcher.discover() }.value
            guard let self, !Task.isCancelled else { return }
            let discovered = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let currentConfigured = configured.compactMap { app in
                discovered[app.id] ?? (FileManager.default.fileExists(atPath: app.path) ? app : nil)
            }
            var seen = Set<String>()
            self.appActions = (currentConfigured + apps).filter { seen.insert($0.id).inserted }.map {
                QuickAction(id: "app." + $0.id, title: $0.displayName, detail: AppLanguage.english ? "Open application" : "打开应用", keywords: $0.name, symbol: "app", destination: .application($0.path))
            }
            self.lastScan = Date()
            self.scan = nil
            if self.window?.isVisible == true, !self.isComposing, !self.executing { self.rebuild(preservingSelection: true) }
        }
    }
}
