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
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        shape.fill()
    }
}

@MainActor
final class QuickActionIconView: NSView {
    private static let appIcons = NSCache<NSString, NSImage>()
    private static func loadAppIcon(_ path: String) -> NSImage {
        if let bundle = Bundle(path: path),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let file = name as NSString
            let ext = file.pathExtension.isEmpty ? "icns" : file.pathExtension
            let base = file.pathExtension.isEmpty ? name : file.deletingPathExtension
            if let url = bundle.url(forResource: base, withExtension: ext),
               let image = NSImage(contentsOf: url) { return image }
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
    private let applicationIcon: Bool

    init(action: QuickAction) {
        if case .application = action.destination { applicationIcon = true }
        else { applicationIcon = false }
        super.init(frame: .zero)
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if case .application(let path) = action.destination {
            Self.appIcons.countLimit = 256
            let key = path as NSString
            let image = Self.appIcons.object(forKey: key) ?? Self.loadAppIcon(path)
            Self.appIcons.setObject(image, forKey: key)
            imageView.image = image
            // Preserve the application's original colors and proportions.
        } else {
            imageView.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            imageView.contentTintColor = .white
        }
        setAccessibilityElement(false)
        imageView.setAccessibilityElement(false)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        let size: CGFloat = applicationIcon ? 28 : 16
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) {
        guard !applicationIcon else { return }
        NSColor.systemIndigo.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
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
    private let favorite = NSButton()
    private let feedback = NSTextField(labelWithString: "")
    private let history: QuickActionHistory
    private var commands: [QuickAction] = []
    private var appActions: [QuickAction] = []
    private var appInventory: [SwitcherApp] = []
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
    var appAlias: ((SwitcherApp) -> String?)?

    init(defaults: UserDefaults = .standard) {
        history = QuickActionHistory(defaults: defaults)
        let panel = QuickActionsPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 254), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
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
        search.placeholderString = AppLanguage.english ? "Search apps and actions…" : "搜索应用与操作…"
        search.font = .systemFont(ofSize: 17, weight: .regular)
        (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        // The insertion caret and header underline indicate search focus without a heavy capsule.
        let separator = NSBox()
        separator.boxType = .separator
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("quickActions.search")
        search.setAccessibilityLabel(AppLanguage.english ? "Search actions and apps" : "搜索操作与应用")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 40
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
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: AppLanguage.english ? "Quick Actions Settings" : "快捷操作设置")!, target: self, action: #selector(openSettings))
        settings.isBordered = false
        settings.toolTip = AppLanguage.english ? "Quick Actions Settings" : "快捷操作设置"
        favorite.isBordered = false
        favorite.target = self
        favorite.action = #selector(toggleFavorite(_:))
        favorite.imagePosition = .imageOnly
        favorite.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let footer = NSStackView(views: [feedback, NSView(), favorite, settings])
        footer.spacing = 8
        for view in [search, separator, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.heightAnchor.constraint(equalToConstant: 30),
            separator.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
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
        rebuildAppActions()
        rebuild()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let width = min(560, area.width - 32)
            let height = min(102 + CGFloat(max(1, min(7, results.count))) * 40, area.height - 32)
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
        if query.isEmpty { results = Array(results.prefix(4)) }
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
        updateFavorite()
        if let window, window.isVisible {
            let available = window.screen?.visibleFrame.height ?? 800
            let height = min(102 + CGFloat(max(1, min(7, results.count))) * 40, available - 32)
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
        }
        feedback.stringValue = results.isEmpty ? (AppLanguage.english ? "No results · Try an app name" : "没有匹配项，试试应用名或操作关键词") : (AppLanguage.english ? "↑↓ Select    ↵ Open" : "↑↓ 选择    ↵ 打开")
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
    func tableViewSelectionDidChange(_ notification: Notification) { updateFavorite() }
    private func updateFavorite() {
        guard results.indices.contains(table.selectedRow) else { favorite.isHidden = true; return }
        let action = results[table.selectedRow]
        favorite.isHidden = action.id == "content.text" || action.id == "awake.custom"
        let saved = history.favorites.contains(action.id)
        favorite.image = NSImage(systemSymbolName: saved ? "star.fill" : "star", accessibilityDescription: nil)
        favorite.contentTintColor = .secondaryLabelColor
        let label = AppLanguage.english ? (saved ? "Remove favorite" : "Add favorite") : (saved ? "取消收藏" : "收藏操作")
        favorite.toolTip = label
        favorite.setAccessibilityLabel(label + " " + action.title)
    }
    @objc private func toggleFavorite(_ sender: NSButton) {
        guard results.indices.contains(table.selectedRow) else { return }
        let id = results[table.selectedRow].id
        history.toggleFavorite(id)
        rebuild()
        if let row = results.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateFavorite()
        window?.makeFirstResponder(search)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { QuickActionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let action = results[row]
        let icon = QuickActionIconView(action: action)
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        let highlighted = NSMutableAttributedString(string: action.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        for range in action.highlightRanges(search.stringValue) {
            highlighted.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.22)], range: range)
        }
        title.attributedStringValue = highlighted
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: action.detail.isEmpty ? [title] : [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let content = NSStackView(views: [icon, labels, NSView()])
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        content.setAccessibilityLabel(action.title + " " + action.detail)
        return content
    }
    static func appTitle(_ app: SwitcherApp, alias: String?) -> String {
        let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !alias.isEmpty, alias.caseInsensitiveCompare(app.displayName) != .orderedSame else { return app.displayName }
        return "\(alias)（\(app.displayName)）"
    }
    private func rebuildAppActions() {
        let discovered = Dictionary(appInventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let configured = (configuredApps?() ?? []).compactMap { app in
            discovered[app.id] ?? (FileManager.default.fileExists(atPath: app.path) ? app : nil)
        }
        var seen = Set<String>()
        appActions = (configured + appInventory).filter { seen.insert($0.id).inserted }.map { app in
            QuickAction(id: "app." + app.id, title: Self.appTitle(app, alias: appAlias?(app)), detail: AppLanguage.english ? "Open application" : "打开应用", keywords: app.name, symbol: "app", destination: .application(app.path))
        }
    }
    private func refreshApps() {
        guard scan == nil, Date().timeIntervalSince(lastScan) > 60 else { return }
        scan = Task { [weak self] in
            let apps = await Task.detached(priority: .utility) { AppSwitcher.discover() }.value
            guard let self, !Task.isCancelled else { return }
            self.appInventory = apps
            self.rebuildAppActions()
            self.lastScan = Date()
            self.scan = nil
            if self.window?.isVisible == true, !self.isComposing, !self.executing { self.rebuild(preservingSelection: true) }
        }
    }
}
