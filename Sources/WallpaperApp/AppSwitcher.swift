import AppKit
import Carbon
import UniformTypeIdentifiers

struct SwitcherApp: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
}
struct SwitcherBinding: Codable, Equatable {
    var path: String
    var name: String
    var shortcut: ClipboardShortcut?
    var showInPanel = false
}

// No keyboard content is captured: only the current modifier state is sampled.
struct OptionHoldState {
    private var began: TimeInterval?
    private var suppressed = false
    mutating func suppress() { suppressed = true }
    mutating func visible(optionOnly: Bool, now: TimeInterval, delay: TimeInterval = 0.45) -> Bool {
        guard optionOnly else { began = nil; suppressed = false; return false }
        guard !suppressed else { return false }
        if began == nil { began = now }
        return now - (began ?? now) >= delay
    }
}

@MainActor
final class AppSwitcher: NSObject {
    private let defaults: UserDefaults
    private(set) var bindings: [String: SwitcherBinding] = [:]
    private var shortcuts: [String: GlobalClipboardShortcut] = [:]
    private(set) var failures: [String: String] = [:]
    private(set) var loadError: String?
    private var timer: Timer?
    private var hold = OptionHoldState()
    private var panel: NSPanel?
    private var configurationOpen = false
    private(set) var featureEnabled = true
    var onChange: (() -> Void)?
    var holdDelay: TimeInterval {
        get { Self.validDelay(defaults.object(forKey: "appSwitcherHoldDelay") as? Double ?? 0.45) }
        set {
            defaults.set(Self.validDelay(newValue), forKey: "appSwitcherHoldDelay")
            hold = OptionHoldState(); panel?.orderOut(nil)
        }
    }
    private static func validDelay(_ value: Double) -> Double {
        value.isFinite ? min(5, max(0.1, value)) : 0.45
    }
    var panelEnabled: Bool {
        get { defaults.object(forKey: "appSwitcherPanelEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "appSwitcherPanelEnabled"); updateTimer(); onChange?() }
    }
    init(defaults: UserDefaults = .standard, start: Bool = true) {
        self.defaults = defaults
        super.init()
        if let data = defaults.data(forKey: "appSwitcherBindings") {
            do { bindings = try JSONDecoder().decode([String: SwitcherBinding].self, from: data) }
            catch { loadError = "应用切换配置无法读取，原数据已保留。" }
        }
        if start {
            for (id, binding) in bindings {
                if let value = binding.shortcut { install(value, id: id) }
            }
            updateTimer()
        }
    }
    deinit { timer?.invalidate() }
    // Check declared application resources rather than loading hundreds of icon bitmaps.
    // Manual additions intentionally bypass this automatic-inventory filter.
    nonisolated static func hasApplicationIcon(_ bundle: Bundle) -> Bool {
        let primary = (bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let files = [bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String].compactMap { $0 }
            + (bundle.object(forInfoDictionaryKey: "CFBundleIconFiles") as? [String] ?? [])
            + (primary["CFBundleIconFiles"] as? [String] ?? [])
        for name in files where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if bundle.url(forResource: name, withExtension: nil) != nil
                || bundle.url(forResource: name, withExtension: "icns") != nil { return true }
        }
        let names = [bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, primary["CFBundleIconName"] as? String].compactMap { $0 }
        return names.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && bundle.url(forResource: "Assets", withExtension: "car") != nil
    }
    nonisolated static func discover() -> [SwitcherApp] {
        let roots = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Library/CoreServices"]
        var found: [String: SwitcherApp] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                      !(bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool ?? false),
                      hasApplicationIcon(bundle) else { continue }
                let id = bundle.bundleIdentifier ?? url.standardizedFileURL.path
                if id == "local.tango.macbglive" || found[id] != nil { continue }
                let name = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                            url.deletingPathExtension().lastPathComponent].compactMap { $0 }.first { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } } ?? url.lastPathComponent
                found[id] = SwitcherApp(id: id, name: name, path: url.path)
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    @discardableResult
    private func install(_ value: ClipboardShortcut, id: String) -> Bool {
        let hotkey = shortcuts[id] ?? GlobalClipboardShortcut()
        hotkey.action = { [weak self] in self?.activate(id) }
        guard hotkey.register(value) else { failures[id] = "快捷键被占用，请重新配置"; return false }
        shortcuts[id] = hotkey; failures.removeValue(forKey: id); return true
    }
    func configure(_ app: SwitcherApp, shortcut: ClipboardShortcut?, show: Bool) throws {
        if let loadError { throw error(loadError) }
        if let shortcut {
            guard shortcut.isValid else { throw error("请选择包含 ⌥、⌃ 或 ⌘ 的快捷键。") }
            let same: (ClipboardShortcut) -> Bool = { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }
            guard !same(.saved()), !bindings.contains(where: { $0.key != app.id && $0.value.shortcut.map(same) == true }) else {
                throw error("此快捷键已用于剪贴板或其他应用，原配置已保留。")
            }
            guard !featureEnabled || install(shortcut, id: app.id) else { throw error("无法注册快捷键，可能已被系统或其他应用占用。原配置已保留。") }
        } else { shortcuts.removeValue(forKey: app.id); failures.removeValue(forKey: app.id) }
        bindings[app.id] = SwitcherBinding(path: app.path, name: app.name, shortcut: shortcut, showInPanel: show)
        defaults.set(try JSONEncoder().encode(bindings), forKey: "appSwitcherBindings")
        panel?.orderOut(nil); panel = nil; updateTimer(); onChange?()
    }
    func setVisibility(_ app: SwitcherApp, show: Bool) throws {
        if let loadError { throw error(loadError) }
        var binding = bindings[app.id] ?? SwitcherBinding(path: app.path, name: app.name)
        binding.showInPanel = show; binding.name = app.name; binding.path = app.path
        bindings[app.id] = binding
        defaults.set(try JSONEncoder().encode(bindings), forKey: "appSwitcherBindings")
        panel?.orderOut(nil); panel = nil; updateTimer(); onChange?()
    }
    func containsShortcut(_ value: ClipboardShortcut) -> Bool {
        featureEnabled && bindings.values.contains { $0.shortcut?.keyCode == value.keyCode && $0.shortcut?.modifiers == value.modifiers }
    }
    private func error(_ message: String) -> NSError { NSError(domain: "AppSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func activate(_ id: String) {
        guard featureEnabled else { return }
        guard let binding = bindings[id] else { return }
        hold.suppress(); panel?.orderOut(nil)
        let url = URL(fileURLWithPath: binding.path)
        guard FileManager.default.fileExists(atPath: url.path) else { failures[id] = "应用已移动或卸载，请刷新列表重新配置"; onChange?(); return }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            if running.isActive && !running.isHidden { running.hide() }
            else { running.unhide(); running.activate(options: []) }
            return
        }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error { Task { @MainActor in self?.failures[id] = error.localizedDescription; self?.onChange?() } }
        }
    }
    func setFeatureEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else { return }
        featureEnabled = enabled
        if enabled {
            for (id, binding) in bindings { if let key = binding.shortcut { install(key, id: id) } }
        } else { shortcuts.removeAll(); panel?.orderOut(nil); panel = nil }
        updateTimer()
    }
    func pausePanel(_ value: Bool) { configurationOpen = value; hold.suppress(); panel?.orderOut(nil) }
    private func updateTimer() {
        timer?.invalidate(); timer = nil; panel?.orderOut(nil); hold = OptionHoldState()
        guard featureEnabled, panelEnabled, bindings.values.contains(where: \.showInPanel) else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func tick() {
        let flags = NSEvent.modifierFlags.intersection([.option, .command, .control, .shift])
        let visible = hold.visible(optionOnly: flags == .option, now: ProcessInfo.processInfo.systemUptime, delay: holdDelay)
        guard featureEnabled, visible, !configurationOpen else { panel?.orderOut(nil); return }
        if panel == nil { panel = makePanel() }
        guard let panel, !panel.isVisible else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }
    func makePanel() -> NSPanel {
        let items = bindings.sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }.filter { $0.value.showInPanel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: min(540, 72 + items.count * 42)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = NSView(); root.wantsLayer = true; root.layer?.cornerRadius = 16
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.98).cgColor
        root.layer?.masksToBounds = true; panel.contentView = root; panel.appearance = NSAppearance(named: .darkAqua)
        let title = NSTextField(labelWithString: AppLanguage.english ? "App Switcher · Hold ⌥" : "应用切换 · 按住 ⌥")
        title.font = .systemFont(ofSize: 16, weight: .semibold); title.frame = NSRect(x: 20, y: panel.frame.height - 42, width: 380, height: 24)
        root.addSubview(title)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 396, height: panel.frame.height - 64))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = SwitcherFlippedView(frame: NSRect(x: 0, y: 0, width: 380, height: items.count * 42))
        for (index, item) in items.enumerated() {
            let button = SettingsFeedbackButton(title: item.value.name + "   " + (item.value.shortcut?.label ?? "—"), target: self, action: #selector(panelClick(_:)))
            button.frame = NSRect(x: 0, y: index * 42, width: 380, height: 36)
            button.cell?.representedObject = item.key
            button.toolTip = failures[item.key] ?? item.value.path
            document.addSubview(button)
        }
        scroll.documentView = document; root.addSubview(scroll); return panel
    }
    @objc private func panelClick(_ sender: NSButton) { if let id = sender.cell?.representedObject as? String { activate(id) } }
}

private final class SwitcherFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
final class AppSwitcherSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let manager: AppSwitcher
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var apps: [SwitcherApp] = []
    private var filtered: [SwitcherApp] = []
    private var scanTask: Task<Void, Never>?
    private let refreshButton = SettingsFeedbackButton()
    private let delaySlider = NSSlider(value: 0.45, minValue: 0.1, maxValue: 5, target: nil, action: nil)
    private let delayLabel = NSTextField(labelWithString: "")
    init(manager: AppSwitcher) {
        self.manager = manager
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: AppLanguage.english ? "App Switcher" : "应用切换")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Set shortcuts to activate or launch apps. Choose which apps appear when holding Option. Hidden apps keep their shortcuts. Apps without an icon can be added manually."
            : "配置快捷键以切换或启动应用。长按 Option 显示勾选的应用，松开隐藏；取消展示不会停用快捷键。无独立图标的应用请手动添加。")
        hint.textColor = .secondaryLabelColor
        enabled.title = AppLanguage.english ? "Show app panel when holding Option" : "长按 Option 显示应用切换面板"
        enabled.state = manager.panelEnabled ? .on : .off
        enabled.target = self; enabled.action = #selector(togglePanel)
        search.placeholderString = AppLanguage.english ? "Search installed apps" : "搜索应用名称或路径"
        search.delegate = self
        refreshButton.title = AppLanguage.english ? "Refresh apps" : "刷新应用"
        refreshButton.target = self; refreshButton.action = #selector(scan)
        let addApp = SettingsFeedbackButton(title: AppLanguage.english ? "Add app…" : "添加应用…", target: self, action: #selector(addApplication))
        let row = NSStackView(views: [search, refreshButton, addApp]); row.spacing = 12
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        delaySlider.doubleValue = manager.holdDelay
        delaySlider.target = self; delaySlider.action = #selector(changeDelay)
        delaySlider.isContinuous = true
        delaySlider.setAccessibilityLabel(AppLanguage.english ? "Option hold delay in seconds" : "Option 长按响应时间（秒）")
        delaySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        delayLabel.widthAnchor.constraint(equalToConstant: 65).isActive = true
        updateDelayLabel()
        let delayRow = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Hold delay" : "长按响应时间"), delaySlider, delayLabel])
        delayRow.spacing = 12
        delayRow.toolTip = AppLanguage.english ? "0.10–5.00 seconds · Saved automatically" : "0.10–5.00 秒 · 自动保存"
        let top = NSStackView(views: [heading, hint, enabled, delayRow, row]); top.orientation = .vertical; top.alignment = .leading; top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false; addSubview(top)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        table.rowHeight = 46; table.intercellSpacing = NSSize(width: 8, height: 4)
        table.usesAlternatingRowBackgroundColors = true; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("app", AppLanguage.english ? "Application" : "应用", 310.0),
                                    ("shortcut", AppLanguage.english ? "Shortcut" : "快捷键", 205.0),
                                    ("show", AppLanguage.english ? "Show in panel" : "面板中展示", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.setAccessibilityLabel(AppLanguage.english ? "Installed applications" : "已安装应用列表")
        scroll.documentView = table; scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12)
        status.translatesAutoresizingMaskIntoConstraints = false; addSubview(status)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 24), top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), hint.widthAnchor.constraint(equalTo: top.widthAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor), status.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
        manager.onChange = { [weak self] in self?.reload() }
        scan()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func addApplication() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url: url) else { return }
        let id = bundle.bundleIdentifier ?? url.standardizedFileURL.path
        guard id != Bundle.main.bundleIdentifier else { return }
        let app = SwitcherApp(id: id, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent, path: url.path)
        apps.removeAll { $0.id == id }; apps.append(app)
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do { try manager.setVisibility(app, show: manager.bindings[id]?.showInPanel ?? false) }
        catch { showError(error) }
        search.stringValue = app.name; reload()
    }
    @objc private func scan() {
        guard scanTask == nil else { return }
        refreshButton.isEnabled = false
        status.stringValue = AppLanguage.english ? "Scanning application folders…" : "正在扫描应用目录…"
        scanTask = Task { [weak self] in
            let apps = await Task.detached(priority: .utility) { AppSwitcher.discover() }.value
            guard let self else { return }
            self.applyInventory(apps)
            self.refreshButton.isEnabled = true; self.scanTask = nil

        }
    }
    func applyInventory(_ inventory: [SwitcherApp]) {
        apps = inventory
        let ids = Set(inventory.map(\.id))
        apps += manager.bindings.filter { !ids.contains($0.key) }.map { SwitcherApp(id: $0.key, name: $0.value.name, path: $0.value.path) }
        reload()
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = apps.filter { query.isEmpty || ($0.name + " " + $0.path).localizedStandardContains(query) }
        table.reloadData()
        status.stringValue = manager.loadError ?? (AppLanguage.english
            ? "\(filtered.count) apps · Click to record · Esc cancels · Backspace clears · Auto-saved"
            : "\(filtered.count) 个应用 · 点击录入 · Esc 取消 · Backspace 清除 · 配置自动保存")
    }
    private func updateDelayLabel() {
        delayLabel.stringValue = String(format: "%.2f %@", manager.holdDelay, AppLanguage.english ? "s" : "秒")
    }
    @objc private func changeDelay() {
        manager.holdDelay = (delaySlider.doubleValue * 20).rounded() / 20
        delaySlider.doubleValue = manager.holdDelay
        updateDelayLabel()
    }
    @objc private func togglePanel() { manager.panelEnabled = enabled.state == .on }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row), let column = tableColumn else { return nil }
        let app = filtered[row], binding = manager.bindings[app.id]
        let key = column.identifier
        if key.rawValue == "app" {
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = key
            if cell.textField == nil {
                let label = NSTextField(labelWithString: ""); label.frame = NSRect(x: 36, y: 12, width: 265, height: 20)
                label.autoresizingMask = [.width]; label.lineBreakMode = .byTruncatingMiddle
                let icon = NSImageView(frame: NSRect(x: 3, y: 9, width: 28, height: 28))
                cell.addSubview(label); cell.addSubview(icon); cell.textField = label; cell.imageView = icon
            }
            cell.textField?.stringValue = app.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: app.path)
            cell.toolTip = app.path
            return cell
        }
        if key.rawValue == "shortcut" {
            let recorder = tableView.makeView(withIdentifier: key, owner: self) as? SwitcherShortcutRecorder ?? SwitcherShortcutRecorder()
            recorder.cancelRecording()
            recorder.identifier = key
            recorder.title = binding?.shortcut?.label ?? (AppLanguage.english ? "Click to record" : "点击录入快捷键")
            recorder.toolTip = AppLanguage.english ? "Press a shortcut · Esc cancels · Backspace clears" : "按下组合键 · Esc 取消 · Backspace 清除"
            recorder.setAccessibilityLabel(app.name + " · " + column.title)
            recorder.onRecordingChanged = { [weak manager] value in manager?.pausePanel(value) }
            recorder.onRecord = { [weak self] value in
                guard let self else { return }
                do {
                    try self.manager.configure(app, shortcut: value, show: self.manager.bindings[app.id]?.showInPanel ?? false)
                    self.status.textColor = .secondaryLabelColor
                } catch {
                    self.status.textColor = .systemRed
                    self.status.stringValue = error.localizedDescription
                }
            }
            return recorder
        }
        let button = tableView.makeView(withIdentifier: key, owner: self) as? NSButton
            ?? NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.identifier = key; button.cell?.representedObject = app.id; button.target = self
        button.title = AppLanguage.english ? "Show" : "展示"
        button.state = binding?.showInPanel == true ? .on : .off; button.action = #selector(toggleApp(_:))
        button.toolTip = manager.failures[app.id] ?? app.path
        button.setAccessibilityLabel(app.name + " · " + column.title)
        return button
    }
    private func app(for sender: NSButton) -> SwitcherApp? {
        guard let id = sender.cell?.representedObject as? String else { return nil }
        return apps.first { $0.id == id }
    }
    @objc private func toggleApp(_ sender: NSButton) {
        guard let app = app(for: sender) else { return }
        do { try manager.setVisibility(app, show: sender.state == .on) }
        catch { showError(error); reload() }
    }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
}

// A local recorder exists only while its visible row is being edited.
@MainActor
final class SwitcherShortcutRecorder: NSButton {
    private(set) var isRecording = false
    private var previousTitle = ""
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    var onRecord: ((ClipboardShortcut?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; target = self; action = #selector(beginRecording)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc func beginRecording() {
        if isRecording { cancelRecording(); return }
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        previousTitle = title; isRecording = true
        title = AppLanguage.english ? "Press shortcut…" : "请按快捷键…"
        contentTintColor = .controlAccentColor
        GlobalClipboardShortcut.setRecording(true); onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.type == .keyDown else { self.cancelRecording(); return event }
            guard event.window === self.window else { self.cancelRecording(); return event }
            self.handleKey(event); return nil
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            })
        }
    }
    func handleKey(_ event: NSEvent) {
        guard isRecording, !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            cancelRecording(); onRecord?(nil); return
        }
        guard let value = ClipboardShortcut.from(event) else {
            title = AppLanguage.english ? "Use ⌃ / ⌥ / ⌘ + key" : "需要 ⌃ / ⌥ / ⌘ 组合键"
            return
        }
        cancelRecording(); onRecord?(value)
    }
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        title = previousTitle; contentTintColor = nil
        GlobalClipboardShortcut.setRecording(false); onRecordingChanged?(false)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelRecording(); super.viewWillMove(toWindow: newWindow)
    }
    override func resignFirstResponder() -> Bool { cancelRecording(); return super.resignFirstResponder() }
}
