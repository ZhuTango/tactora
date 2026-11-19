import AppKit
import Quartz
import UniformTypeIdentifiers

@MainActor
final class QuickActionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickActionRowView: NSTableRowView {
    static let matchColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.47, green: 0.89, blue: 0.82, alpha: 1)
            : NSColor(srgbRed: 0.02, green: 0.36, blue: 0.32, alpha: 1)
    }

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
        if case .file = action.destination { applicationIcon = true }
        else if case .application = action.destination { applicationIcon = true }
        else { applicationIcon = false }
        super.init(frame: .zero)
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if case .file(let path) = action.destination {
            imageView.image = NSWorkspace.shared.icon(forFile: path)
        } else if case .application(let path) = action.destination {
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
final class QuickActionsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    let search = NSSearchField()
    let table = NSTableView()
    private let scopeButton = NSButton()
    private let favorite = NSButton()
    private let feedback = NSTextField(labelWithString: "")
    private var fileRequest = 0
    private var fileDebounce: Task<Void, Never>?
    private var fileObserver: NSObjectProtocol?
    private var previewPanel: NSPanel?
    var fileIndexProvider: () -> FileSearchIndex = { FileSearchIndex.shared }
    private let history: QuickActionHistory
    private let currencyRates: CurrencyRates
    private var currencyTask: Task<Void, Never>?
    private var currencyQuery: CurrencyQuery?
    private var currencyResult: Result<CurrencyRates.Quote, Error>?
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

    init(defaults: UserDefaults = .standard, currencyRates: CurrencyRates? = nil) {
        self.currencyRates = currencyRates ?? CurrencyRates(defaults: defaults)
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
        search.placeholderString = AppLanguage.english ? "Search apps, actions and files…" : "搜索应用、操作与文件…"
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
        let fileMenu = NSMenu()
        fileMenu.delegate = self
        for (title, selector) in [(AppLanguage.english ? "Open in Default App" : "用默认应用打开", #selector(openSelectedInDefaultApp)), (AppLanguage.english ? "Show in Finder" : "在 Finder 中显示", #selector(revealSelectedFile)), (AppLanguage.english ? "Copy Path" : "复制路径", #selector(copySelectedFilePath)), (AppLanguage.english ? "Preview" : "预览", #selector(previewSelectedFile))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; fileMenu.addItem(item)
        }
        table.menu = fileMenu
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
        scopeButton.title = AppLanguage.english ? "Search scope…" : "查看检索范围…"
        scopeButton.bezelStyle = .inline
        scopeButton.target = self
        scopeButton.action = #selector(showSearchScope)
        scopeButton.isHidden = true
        let footer = NSStackView(views: [feedback, NSView(), scopeButton, favorite, settings])
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
        fileRequest += 1; fileDebounce?.cancel(); fileDebounce = nil
        previewPanel?.orderOut(nil); previewPanel = nil
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver); self.fileObserver = nil }
        currencyTask?.cancel(); currencyTask = nil
        currencyQuery = nil; currencyResult = nil
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
        if window?.isVisible == true, !executing, window?.attachedSheet == nil, previewPanel?.isVisible != true { dismiss(restoreFocus: false) }
    }
    var isComposing: Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    private func installMonitors() {
        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let source = event.window, !self.isComposing else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if source === self.previewPanel, flags.isEmpty, [49, 53].contains(event.keyCode) {
                if !event.isARepeat { self.previewPanel?.orderOut(nil) }
                return nil
            }
            guard source === self.window else { return event }
            if event.keyCode == 53 { self.dismiss(restoreFocus: true); return nil }
            guard !self.executing else { return event }
            if self.selectedFilePath != nil {
                if event.keyCode == 36 && flags == [.command] { self.revealSelectedFile(); return nil }
                if event.keyCode == 8 && flags == [.command, .shift] { self.copySelectedFilePath(); return nil }
                if event.keyCode == 49 && (flags.isEmpty || flags == [.option]) {
                    if !event.isARepeat { self.previewSelectedFile() }
                    return nil
                }
                if event.keyCode == 49, flags == [.shift], let editor = self.search.currentEditor() as? NSTextView {
                    editor.insertText(" ", replacementRange: editor.selectedRange())
                    return nil
                }
            }
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
            if let self, event.window !== self.window, event.window !== self.previewPanel, self.window?.attachedSheet == nil { self.dismiss(restoreFocus: false) }
            return event
        }) { monitors.append(token) }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard !isComposing else { return }
        rebuild()
    }
    func rebuild(preservingSelection: Bool = false) {
        scopeButton.isHidden = true
        let previousFileResults = preservingSelection ? results.filter { if case .file = $0.destination { return true }; return false } : []
        let selectedID = preservingSelection && results.indices.contains(table.selectedRow) ? results[table.selectedRow].id : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count <= TextProcessor.maximumBytes else {
            updateCurrency("")
            fileRequest += 1; fileDebounce?.cancel(); fileDebounce = nil
            results = []; table.reloadData()
            feedback.stringValue = AppLanguage.english ? "Input exceeds 1 MB" : "输入超过 1 MB，请缩短内容"
            return
        }
        if query.hasPrefix("/") {
            updateCurrency("")
            rebuildFiles(query, selectedID: selectedID)
            return
        }
        fileRequest += 1; fileDebounce?.cancel(); fileDebounce = nil
        if !preservingSelection { previewPanel?.orderOut(nil) }
        updateCurrency(query)
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
        if let amount = CurrencyQuery.suggestion(query) {
            results.append(QuickAction(id: "content.currencyHint",
                title: AppLanguage.english ? "Currency conversion" : "汇率换算",
                detail: CurrencyQuery.completion(amount: amount, english: AppLanguage.english).text + (AppLanguage.english ? " · Return to try; edit currency" : " · 回车试算，可直接改为日元、欧元"),
                symbol: "dollarsign.arrow.circlepath", destination: .command("currency.suggest")))
        }
        let calculation = QuickCalculator.evaluate(query)
        if case .success(let value) = calculation {
            results.insert(QuickAction(id: "content.calculation", title: "= " + value,
                detail: AppLanguage.english ? "Return to copy result · % means ÷100" : "回车复制结果 · % 表示除以 100",
                symbol: "equal", destination: .calculation(value)), at: 0)
        }
        if let currencyQuery, case .success(let quote) = currencyResult {
            let source = quote.date.isEmpty ? (AppLanguage.english ? "Same currency" : "同币种")
                : "Frankfurter · " + quote.date + (quote.cached ? (AppLanguage.english ? " · cached" : " · 缓存汇率") : "")
            results.insert(QuickAction(id: "content.currency", title: "≈ " + quote.value + " " + currencyQuery.to,
                detail: "1 \(currencyQuery.from) = \(quote.rate) \(currencyQuery.to) · " + source,
                symbol: "dollarsign.arrow.circlepath", destination: .calculation(quote.value)), at: 0)
        }
        let shouldSearchFiles = !query.isEmpty && query.count <= 256 && calculation == nil && currencyQuery == nil && results.first?.id != "content.text"
        let baseResults = results
        if shouldSearchFiles { results += previousFileResults }
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
        if currencyQuery != nil {
            switch currencyResult {
            case .success: feedback.stringValue = AppLanguage.english ? "↵ Copy amount · Reference rate" : "↵ 复制金额 · 参考汇率，非成交价"
            case .failure(let error):
                feedback.stringValue = (error as? CurrencyRates.Failure) == .unsupported
                    ? (AppLanguage.english ? "Currency not supported by this rate source" : "汇率源暂不支持该币种")
                    : (AppLanguage.english ? "Rates unavailable · Edit query or reopen to retry" : "汇率获取失败，修改输入或重新打开重试")
            case nil: feedback.stringValue = AppLanguage.english ? "Fetching exchange rates…" : "正在获取汇率…"
            }
        } else if case .failure(let error) = calculation, results.isEmpty {
            switch error {
            case .divisionByZero: feedback.stringValue = AppLanguage.english ? "Cannot divide by zero" : "除数不能为 0"
            case .outOfRange: feedback.stringValue = AppLanguage.english ? "Result is outside the supported range" : "结果超出可计算范围"
            case .invalid: feedback.stringValue = AppLanguage.english ? "Enter a complete expression, e.g. 12*(3+4)" : "请输入完整算式，例如 12*(3+4)"
            }
        } else if results.first?.id == "content.calculation" {
            feedback.stringValue = AppLanguage.english ? "↑↓ Select    ↵ Copy result" : "↑↓ 选择    ↵ 复制结果"
        }
        if shouldSearchFiles {
            rebuildFiles(query, selectedID: selectedID, baseResults: baseResults)
        }
    }
    private func updateCurrency(_ text: String) {
        let query = CurrencyQuery.parse(text)
        guard query != currencyQuery else { return }
        currencyTask?.cancel(); currencyTask = nil
        currencyQuery = query; currencyResult = nil
        guard let query else { return }
        let token = generation
        currencyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                let quote = try await self.currencyRates.quote(query)
                guard !Task.isCancelled, self.generation == token, self.currencyQuery == query else { return }
                self.currencyResult = .success(quote)
                if !self.isComposing { self.rebuild(preservingSelection: true) }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.currencyQuery == query else { return }
                self.currencyResult = .failure(error)
                if !self.isComposing { self.rebuild(preservingSelection: true) }
            }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if results.indices.contains(table.clickedRow) { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        for item in menu.items { item.isHidden = selectedFilePath == nil }
    }
    private var selectedFilePath: String? {
        let row = table.selectedRow
        guard results.indices.contains(row), case .file(let path) = results[row].destination else { return nil }
        return path
    }
    @objc private func revealSelectedFile() {
        guard let path = selectedFilePath else { return }
        guard FileManager.default.fileExists(atPath: path) else { feedback.stringValue = AppLanguage.english ? "File no longer exists" : "文件已不存在"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        dismiss(restoreFocus: false)
    }
    @objc private func copySelectedFilePath() {
        guard let path = selectedFilePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        feedback.stringValue = AppLanguage.english ? "Path copied" : "已复制路径"
    }
    private func previewsByDefault(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }
    @objc private func previewSelectedFile() { showFilePreview(toggle: true) }
    private func showFilePreview(toggle: Bool) {
        guard let path = selectedFilePath, FileManager.default.fileExists(atPath: path) else {
            feedback.stringValue = AppLanguage.english ? "File no longer exists" : "文件已不存在"
            return
        }
        if let panel = previewPanel, panel.isVisible {
            let current = (panel.contentView as? QLPreviewView)?.previewItem as? NSURL
            if current?.path == path {
                if toggle { panel.orderOut(nil) } else { panel.orderFront(nil) }
                return
            }
            panel.orderOut(nil)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = (path as NSString).lastPathComponent
        panel.isReleasedWhenClosed = false
        let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 620, height: 480), style: .normal)!
        view.autoresizingMask = [.width, .height]
        view.previewItem = URL(fileURLWithPath: path) as NSURL
        view.autostarts = true
        panel.contentView = view; panel.level = .floating
        panel.center(); previewPanel = panel; panel.orderFront(nil)
    }
    private func rebuildFiles(_ query: String, selectedID: String?, baseResults: [QuickAction] = []) {
        let filesOnly = query.hasPrefix("/")
        let index = fileIndexProvider()
        if fileObserver == nil {
            fileObserver = NotificationCenter.default.addObserver(forName: FileSearchIndex.changed, object: index, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.window?.isVisible == true, !self.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.isComposing else { return }
                    self.rebuild(preservingSelection: true)
                }
            }
        }
        fileRequest += 1
        let request = fileRequest
        fileDebounce?.cancel()
        if filesOnly && selectedID == nil {
            results = []; table.reloadData(); updateFavorite()
            previewPanel?.orderOut(nil)
        }
        if filesOnly || baseResults.isEmpty { feedback.stringValue = AppLanguage.english ? "Searching file index…" : "正在搜索文件索引…" }
        fileDebounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            index.search(filesOnly ? String(query.dropFirst()) : query, limit: 81) { [weak self] matches, state in
                guard let self, !self.isComposing, self.fileRequest == request, self.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                let files = matches.prefix(80)
                let currentID = self.results.indices.contains(self.table.selectedRow) ? self.results[self.table.selectedRow].id : selectedID
                self.results = baseResults + files.map { file in
                    QuickAction(id: "file:" + file.path, title: file.name, detail: (((file.path as NSString).deletingLastPathComponent) as NSString).abbreviatingWithTildeInPath + " · " + file.modified.formatted(date: .numeric, time: .shortened), symbol: file.directory ? "folder" : "doc", destination: .file(file.path))
                }
                self.table.reloadData()
                if !self.results.isEmpty {
                    let row = currentID.flatMap { id in self.results.firstIndex { $0.id == id } } ?? 0
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                self.updateFavorite()
                let status = FileSearchSettingsView.status(state)
                self.scopeButton.isHidden = !files.isEmpty
                if files.isEmpty {
                    self.feedback.stringValue = (AppLanguage.english ? "No matching files · " : "未找到匹配文件 · ") + status
                } else if matches.count > files.count {
                    self.feedback.stringValue = AppLanguage.english ? "Top 80 files · Refine your search" : "已显示前 80 个文件结果，可继续输入缩小范围"
                } else if filesOnly || baseResults.isEmpty {
                    self.feedback.stringValue = status + (AppLanguage.english ? " · ⌘↵ Finder · Space Preview" : " · ⌘↵ 定位 · 空格预览")
                }
                self.feedback.toolTip = status + (AppLanguage.english ? " · ⌘↵ Show file · Space Preview · ⇧Space Insert space · ⌘⇧C Copy path" : " · ⌘↵ 定位文件 · 空格预览 · ⇧空格输入空格 · ⌘⇧C 复制路径")
                if let window = self.window, window.isVisible {
                    let height = min(102 + CGFloat(max(1, min(7, self.results.count))) * 40, (window.screen?.visibleFrame.height ?? 800) - 32)
                    let frame = window.frame
                    window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
                }
            }
        }
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
        guard !isComposing, !executing, results.indices.contains(row) else { return }
        let action = results[row]
        if action.id == "files.search" {
            search.stringValue = "/"; rebuild(); window?.makeFirstResponder(search)
            return
        }
        if action.id == "content.currencyHint", let amount = CurrencyQuery.suggestion(search.stringValue) {
            let completion = CurrencyQuery.completion(amount: amount, english: AppLanguage.english)
            search.stringValue = completion.text
            rebuild()
            window?.makeFirstResponder(search)
            if let editor = search.currentEditor() as? NSTextView {
                editor.setSelectedRange(completion.selection)
            }
            return
        }
        if let path = selectedFilePath, previewsByDefault(path) {
            showFilePreview(toggle: false)
            return
        }
        execute(action)
    }
    @objc private func openSelectedInDefaultApp() {
        guard selectedFilePath != nil, !executing else { return }
        execute(results[table.selectedRow])
    }
    private func execute(_ action: QuickAction) {
        guard let context, let onExecute else { return }
        let token = generation
        executing = true
        search.isEnabled = false
        onExecute(action, context) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.executing = false
            self.search.isEnabled = true
            switch result {
            case .success:
                if !action.id.hasPrefix("content.") && !action.id.hasPrefix("file:") && action.id != "awake.custom" { self.history.record(action.id) }
                self.dismiss(restoreFocus: false)
            case .failure(let error):
                self.feedback.stringValue = error.localizedDescription
                self.feedback.toolTip = error.localizedDescription
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.search)
            }
        }
    }
    @objc private func showSearchScope() {
        let state = fileIndexProvider().state
        let alert = NSAlert()
        alert.messageText = AppLanguage.english ? "File search scope" : "文件检索范围"
        let sections = [(AppLanguage.english ? "Indexed" : "检索目录", state.roots),
                        (AppLanguage.english ? "Excluded" : "排除目录", state.exclusions),
                        (AppLanguage.english ? "Unavailable" : "无法访问", state.unavailable)]
        alert.informativeText = sections.map { title, paths in
            title + "\n" + (paths.isEmpty ? (AppLanguage.english ? "None" : "无") : paths.joined(separator: "\n"))
        }.joined(separator: "\n\n")
        alert.addButton(withTitle: AppLanguage.english ? "Done" : "完成")
        alert.addButton(withTitle: AppLanguage.english ? "Manage folders…" : "管理目录…")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertSecondButtonReturn { self?.openSettings() }
        }
    }
    @objc private func openSettings() { dismiss(restoreFocus: false); onSettings?() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateFavorite() }
    private func updateFavorite() {
        guard results.indices.contains(table.selectedRow) else { favorite.isHidden = true; return }
        let action = results[table.selectedRow]
        favorite.isHidden = action.id.hasPrefix("content.") || action.id.hasPrefix("file:") || action.id == "awake.custom"
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
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        let highlighted = NSMutableAttributedString(string: action.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let highlightQuery: String
        if case .file = action.destination {
            let input = search.stringValue
            highlightQuery = FileSearchQuery(input.hasPrefix("/") ? String(input.dropFirst()) : input).terms.joined(separator: " ")
        } else { highlightQuery = search.stringValue }
        let matchAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: QuickActionRowView.matchColor
        ]
        for range in action.highlightRanges(highlightQuery) {
            highlighted.addAttributes(matchAttributes, range: range)
        }
        title.attributedStringValue = highlighted
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: action.detail.isEmpty ? [title] : [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        title.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        if !action.detail.isEmpty { detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true }
        let content = NSView()
        for view in [icon as NSView, labels] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        content.setAccessibilityLabel(action.title + " " + action.detail)
        switch action.destination {
        case .file: break
        default: content.toolTip = action.title + "\n" + action.detail
        }
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
