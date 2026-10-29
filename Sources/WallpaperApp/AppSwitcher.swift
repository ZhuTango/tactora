import AppKit
import Carbon
import UniformTypeIdentifiers

struct SwitcherApp: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    var displayName: String {
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return filename != name && filename.localizedCaseInsensitiveContains(name) ? filename : name
    }
}
struct SwitcherBinding: Codable, Equatable {
    var path: String
    var name: String
    var shortcut: ClipboardShortcut?
    var showInPanel = false
    var alias: String?
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
    private var panelScreenWidth: CGFloat?
    private var activationObserver: NSObjectProtocol?
    private var lastActiveID: String?
    private var switchCounts: [String: Int] = [:]
    private var panelOrderDirty = false
    var frequencySorting: Bool {
        get { defaults.bool(forKey: "appSwitcherFrequencySorting") }
        set {
            defaults.set(newValue, forKey: "appSwitcherFrequencySorting")
            hidePanelIfVisible(); panel = nil; onChange?()
        }
    }
    func switchCount(for id: String) -> Int { switchCounts[id] ?? 0 }
    // Called only for actual workspace activation events, never shortcut requests.
    func recordActivation(_ id: String, isRegular: Bool = true) {
        guard featureEnabled, id != lastActiveID else { return }
        lastActiveID = id
        guard isRegular, id != "local.tango.macbglive" else { return }
        let count = switchCount(for: id)
        switchCounts[id] = count < Int.max ? count + 1 : count
        defaults.set(switchCounts, forKey: "appSwitcherActivationCounts")
        if frequencySorting { panelOrderDirty = true }
    }
    private func observeActivations() {
        guard activationObserver == nil, featureEnabled else { return }
        lastActiveID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            let regular = app.activationPolicy == .regular
            Task { @MainActor [weak self] in self?.recordActivation(id, isRegular: regular) }
        }
    }
    private var configurationOpen = false
    private(set) var featureEnabled = true
    var onChange: (() -> Void)?
    var holdDelay: TimeInterval {
        get { Self.validDelay(defaults.object(forKey: "appSwitcherHoldDelay") as? Double ?? 0.45) }
        set {
            defaults.set(Self.validDelay(newValue), forKey: "appSwitcherHoldDelay")
            hold = OptionHoldState(); hidePanelIfVisible()
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
        switchCounts = (defaults.dictionary(forKey: "appSwitcherActivationCounts") as? [String: Int] ?? [:]).filter { $0.value >= 0 }
        if let data = defaults.data(forKey: "appSwitcherBindings") {
            do { bindings = try JSONDecoder().decode([String: SwitcherBinding].self, from: data) }
            catch { loadError = "应用切换配置无法读取，原数据已保留。" }
        }
        if start {
            observeActivations()
            for (id, binding) in bindings {
                if let value = binding.shortcut { install(value, id: id) }
            }
            updateTimer()
        }
    }
    deinit {
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
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
        let roots = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Library/CoreServices",
                     "/System/Cryptexes/App/System/Applications"]
        var found: [String: SwitcherApp] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root).resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url) else { continue }
                let package = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
                // These user-facing system apps use nonstandard package types.
                let systemPackages = ["com.apple.finder": "FNDR", "com.apple.Passwords": "XPC!"]
                let specialPackage = bundle.bundleIdentifier.flatMap { systemPackages[$0] }
                guard (package == "APPL" || (specialPackage != nil && package == specialPackage)),
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
    func isConfigured(_ id: String) -> Bool {
        guard let binding = bindings[id] else { return false }
        return binding.showInPanel || binding.shortcut != nil
    }
    func orderedApps(_ apps: [SwitcherApp]) -> [SwitcherApp] {
        let saved = defaults.stringArray(forKey: "appSwitcherOrder") ?? []
        var ranks: [String: Int] = [:]
        for (index, id) in saved.enumerated() where ranks[id] == nil { ranks[id] = index }
        return apps.sorted { lhs, rhs in
            let a = isConfigured(lhs.id), b = isConfigured(rhs.id)
            if a != b { return a }
            if a {
                let x = ranks[lhs.id] ?? Int.max, y = ranks[rhs.id] ?? Int.max
                if x != y { return x < y }
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
    var configuredApps: [SwitcherApp] {
        orderedApps(bindings.map { SwitcherApp(id: $0.key, name: $0.value.name, path: $0.value.path) }).filter { isConfigured($0.id) }
    }
    var panelItems: [SwitcherApp] {
        let manual = configuredApps.filter { bindings[$0.id]?.showInPanel == true }
        guard frequencySorting else { return manual }
        return manual.enumerated().sorted {
            let a = switchCount(for: $0.element.id), b = switchCount(for: $1.element.id)
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    func moveConfigured(_ id: String, offset: Int) {
        guard loadError == nil, offset == -1 || offset == 1 else { return }
        var ids = configuredApps.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        // Retain inactive entries' positions for later re-enabling, after active entries.
        let dormant = (defaults.stringArray(forKey: "appSwitcherOrder") ?? []).filter { !ids.contains($0) }
        defaults.set(ids + dormant, forKey: "appSwitcherOrder")
        hidePanelIfVisible(); panel = nil; onChange?()
    }
    func moveConfigured(_ id: String, before target: String?) {
        guard loadError == nil else { return }
        var ids = configuredApps.map(\.id)
        guard ids.contains(id), target != id, target == nil || ids.contains(target!) else { return }
        ids.removeAll { $0 == id }
        let insertion = target.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(id, at: insertion)
        let dormant = (defaults.stringArray(forKey: "appSwitcherOrder") ?? []).filter { !ids.contains($0) }
        defaults.set(ids + dormant, forKey: "appSwitcherOrder")
        hidePanelIfVisible(); panel = nil; onChange?()
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
            guard !same(.saved()), !WindowManager.savedContains(shortcut, defaults: defaults), !bindings.contains(where: { $0.key != app.id && $0.value.shortcut.map(same) == true }) else {
                throw error("此快捷键已用于剪贴板或其他应用，原配置已保留。")
            }
            guard !featureEnabled || install(shortcut, id: app.id) else { throw error("无法注册快捷键，可能已被系统或其他应用占用。原配置已保留。") }
        } else { shortcuts.removeValue(forKey: app.id); failures.removeValue(forKey: app.id) }
        bindings[app.id] = SwitcherBinding(path: app.path, name: app.name, shortcut: shortcut, showInPanel: show, alias: bindings[app.id]?.alias)
        defaults.set(try JSONEncoder().encode(bindings), forKey: "appSwitcherBindings")
        hidePanelIfVisible(); panel = nil; updateTimer(); onChange?()
    }
    func setVisibility(_ app: SwitcherApp, show: Bool) throws {
        if let loadError { throw error(loadError) }
        var binding = bindings[app.id] ?? SwitcherBinding(path: app.path, name: app.name)
        binding.showInPanel = show; binding.name = app.name; binding.path = app.path
        bindings[app.id] = binding
        defaults.set(try JSONEncoder().encode(bindings), forKey: "appSwitcherBindings")
        hidePanelIfVisible(); panel = nil; updateTimer(); onChange?()
    }
    func displayName(for app: SwitcherApp) -> String { bindings[app.id]?.alias ?? app.displayName }
    func setAlias(_ app: SwitcherApp, alias: String) throws {
        if let loadError { throw error(loadError) }
        var binding = bindings[app.id] ?? SwitcherBinding(path: app.path, name: app.name)
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.alias = trimmed.isEmpty ? nil : trimmed
        bindings[app.id] = binding
        defaults.set(try JSONEncoder().encode(bindings), forKey: "appSwitcherBindings")
        hidePanelIfVisible(); panel = nil; onChange?()
    }
    func containsShortcut(_ value: ClipboardShortcut) -> Bool {
        featureEnabled && bindings.values.contains { $0.shortcut?.keyCode == value.keyCode && $0.shortcut?.modifiers == value.modifiers }
    }
    private func error(_ message: String) -> NSError { NSError(domain: "AppSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func activate(_ id: String) {
        guard featureEnabled else { return }
        guard let binding = bindings[id] else { return }
        hold.suppress(); hidePanelIfVisible()
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
            observeActivations()
            for (id, binding) in bindings { if let key = binding.shortcut { install(key, id: id) } }
        } else {
            shortcuts.removeAll(); hidePanelIfVisible(); panel = nil
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
            lastActiveID = nil
        }
        updateTimer()
    }
    func pausePanel(_ value: Bool) { configurationOpen = value; hold.suppress(); hidePanelIfVisible() }
    private func updateTimer() {
        timer?.invalidate(); timer = nil; hidePanelIfVisible(); hold = OptionHoldState()
        guard featureEnabled, panelEnabled, bindings.values.contains(where: \.showInPanel) else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func hidePanelIfVisible() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }
    private func tick() {
        let flags = NSEvent.modifierFlags.intersection([.option, .command, .control, .shift])
        let visible = hold.visible(optionOnly: flags == .option, now: ProcessInfo.processInfo.systemUptime, delay: holdDelay)
        guard featureEnabled, visible, !configurationOpen else { hidePanelIfVisible(); return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let screenWidth = screen?.visibleFrame.width ?? 1120
        if panel == nil || panelScreenWidth != screenWidth || (panelOrderDirty && panel?.isVisible != true) {
            hidePanelIfVisible()
            panel = makePanel(availableWidth: screenWidth)
            panelScreenWidth = screenWidth
            panelOrderDirty = false
        }
        guard let panel, !panel.isVisible else { return }
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        for button in panel.contentView?.subviews.compactMap({ $0 as? SwitcherIconButton }) ?? [] {
            button.activeApp = button.cell?.representedObject as? String == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        panel.orderFrontRegardless()
    }
    func makePanel(availableWidth: CGFloat? = nil) -> NSPanel {
        let items = panelItems
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let width = min(max(280, CGFloat(items.count) * 116 + 40), max(80, (availableWidth ?? screen?.visibleFrame.width ?? 1120) - 64))
        let scale = min(1, (width - 40) / CGFloat(max(1, items.count)) / 116)
        let startX = (width - CGFloat(items.count) * 116 * scale) / 2
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 52 + 150 * scale),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let root = NSVisualEffectView(); root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 24; root.layer?.masksToBounds = true
        panel.contentView = root
        for (index, app) in items.enumerated() {
            let button = SwitcherIconButton(frame: NSRect(x: startX + CGFloat(index) * 116 * scale, y: 36, width: 108 * scale, height: 150 * scale))
            button.bounds = NSRect(x: 0, y: 0, width: 108, height: 150)
            button.title = displayName(for: app); button.image = NSWorkspace.shared.icon(forFile: app.path)
            button.shortcutText = bindings[app.id]?.shortcut?.label ?? "—"
            button.target = self; button.action = #selector(panelClick(_:)); button.cell?.representedObject = app.id
            button.toolTip = failures[app.id] ?? displayName(for: app) + " · " + button.shortcutText + " · \(switchCount(for: app.id))"
            button.setAccessibilityLabel(displayName(for: app) + " · " + button.shortcutText)
            button.activeApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.id
            root.addSubview(button)
        }
        let hint = NSTextField(labelWithString: AppLanguage.english ? "Hold ⌥ · Click an app or use its shortcut" : "按住 ⌥ · 点击应用或按快捷键切换")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .white.withAlphaComponent(0.75); hint.alignment = .center
        hint.frame = NSRect(x: 12, y: 12, width: width - 24, height: 16)
        root.addSubview(hint)
        return panel
    }
    @objc private func panelClick(_ sender: NSButton) { if let id = sender.cell?.representedObject as? String { activate(id) } }
}

@MainActor
final class SwitcherIconButton: NSButton {
    var shortcutText = "" { didSet { needsDisplay = true } }
    var activeApp = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; setButtonType(.momentaryChange) }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || activeApp || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.24 : hovered ? 0.18 : 0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 15, yRadius: 15).fill()
        }
        image?.draw(in: NSRect(x: 18, y: 12, width: 72, height: 72), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 4, y: 92, width: 100, height: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        (shortcutText as NSString).draw(in: NSRect(x: 3, y: 118, width: 102, height: 20), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph])
    }
}

@MainActor
final class AppSwitcherSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let manager: AppSwitcher
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let frequency = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var apps: [SwitcherApp] = []
    private var filtered: [SwitcherApp] = []
    private var searchIndices: [String: AppSearchIndex] = [:]
    private var scanTask: Task<Void, Never>?
    private let refreshButton = SettingsFeedbackButton()
    private let moveTop = SettingsFeedbackButton()
    private static let dragType = NSPasteboard.PasteboardType("local.tango.lighttools.app-order")
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
        frequency.title = AppLanguage.english ? "Sort Option panel by switch frequency" : "按切换频次排列 Option 面板"
        frequency.state = manager.frequencySorting ? .on : .off
        frequency.identifier = NSUserInterfaceItemIdentifier("appSwitcherFrequencySorting")
        frequency.target = self; frequency.action = #selector(toggleFrequency)
        frequency.toolTip = AppLanguage.english ? "Counts actual foreground switches locally. Ties use manual order. Hover an app to see its count." : "统计实际切到前台的次数，仅保存在本机；同频次使用手动顺序。悬停应用可查看次数。"
        search.placeholderString = AppLanguage.english ? "Search apps, paths or pinyin" : "搜索应用、路径、拼音或首字母"
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
        moveTop.title = AppLanguage.english ? "Move to top" : "置顶"
        moveTop.target = self; moveTop.action = #selector(moveSelectedToTop)
        let orderHint = NSTextField(labelWithString: AppLanguage.english ? "Drag configured apps to reorder · Auto-saved" : "拖拽已配置应用调整顺序 · 自动保存")
        orderHint.textColor = .secondaryLabelColor; orderHint.font = .systemFont(ofSize: 12)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let orderRow = NSStackView(views: [orderHint, spacer, moveTop]); orderRow.spacing = 12
        for button in [refreshButton, addApp, moveTop] {
            button.alignment = .center
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        moveTop.widthAnchor.constraint(equalToConstant: 72).isActive = true
        refreshButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        addApp.widthAnchor.constraint(equalToConstant: 88).isActive = true
        search.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let top = NSStackView(views: [heading, hint, enabled, frequency, delayRow, row, orderRow]); top.orientation = .vertical; top.alignment = .leading; top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false; addSubview(top)
        orderRow.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        table.rowHeight = 48; table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAlternatingRowBackgroundColors = false; table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self; table.delegate = self; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, width) in [("app", AppLanguage.english ? "Application" : "应用", 230.0),
                                    ("alias", AppLanguage.english ? "Display alias" : "显示别名", 170.0),
                                    ("shortcut", AppLanguage.english ? "Shortcut" : "快捷键", 160.0),
                                    ("show", AppLanguage.english ? "Show in panel" : "面板中展示", 115.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            column.minWidth = id == "app" ? 180 : width; column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let orderMenu = NSMenu()
        for (title, offset) in [(AppLanguage.english ? "Move up" : "上移", -1), (AppLanguage.english ? "Move down" : "下移", 1)] {
            let item = NSMenuItem(title: title, action: #selector(reorderApp(_:)), keyEquivalent: "")
            item.target = self; item.tag = offset; orderMenu.addItem(item)
        }
        table.menu = orderMenu
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
        searchIndices.removeAll(keepingCapacity: true)
        apps = inventory
        let ids = Set(inventory.map(\.id))
        apps += manager.bindings.filter { !ids.contains($0.key) }.map { SwitcherApp(id: $0.key, name: $0.value.name, path: $0.value.path) }
        reload()
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { reload() }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? AppAliasField, let app = apps.first(where: { $0.id == field.appID }) else { return }
        do { try manager.setAlias(app, alias: field.stringValue) }
        catch { showError(error); reload() }
    }
    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedID = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        filtered = manager.orderedApps(apps).filter { app in
            if query.isEmpty { return true }
            let source = manager.displayName(for: app) + "\n" + app.displayName + "\n" + app.name + "\n" + app.path
            if searchIndices[app.id]?.source != source { searchIndices[app.id] = AppSearchIndex(source: source) }
            return searchIndices[app.id]!.matches(query)
        }
        table.reloadData()
        if let selectedID, let index = filtered.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updateOrderButtons()
        status.stringValue = manager.loadError ?? (AppLanguage.english
            ? "\(filtered.count) apps · Click to record · Esc cancels · Backspace clears · Auto-saved"
            : "\(filtered.count) 个应用 · 点击录入 · Esc 取消 · Backspace 清除 · 配置自动保存")
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateOrderButtons() }
    private var canReorder: Bool { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func updateOrderButtons() {
        let ids = manager.configuredApps.map(\.id)
        let id = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : ""
        moveTop.isEnabled = ids.contains(id) && ids.first != id
        moveTop.toolTip = AppLanguage.english ? "Move the selected configured app to the first position" : "将选中的已配置应用移到第一位"
    }
    @objc private func moveSelectedToTop() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        manager.moveConfigured(filtered[table.selectedRow].id, before: manager.configuredApps.first?.id)
    }
    @objc private func reorderApp(_ sender: NSMenuItem) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard canReorder, filtered.indices.contains(row) else { return }
        manager.moveConfigured(filtered[row].id, offset: sender.tag)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorder, filtered.indices.contains(row), manager.isConfigured(filtered[row].id) else { return nil }
        let item = NSPasteboardItem(); item.setString(filtered[row].id, forType: Self.dragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard canReorder, let source = info.draggingSource as? NSTableView, source === table,
              let id = info.draggingPasteboard.string(forType: Self.dragType), manager.isConfigured(id) else { return [] }
        let destination = min(max(0, row), manager.configuredApps.count)
        tableView.setDropRow(destination, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard canReorder, let source = info.draggingSource as? NSTableView, source === table,
              let id = info.draggingPasteboard.string(forType: Self.dragType), manager.isConfigured(id) else { return false }
        let ids = manager.configuredApps.map(\.id)
        let destination = min(max(0, row), ids.count)
        manager.moveConfigured(id, before: destination < ids.count ? ids[destination] : nil)
        if let index = filtered.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return true
    }
    private func updateDelayLabel() {
        delayLabel.stringValue = String(format: "%.2f %@", manager.holdDelay, AppLanguage.english ? "s" : "秒")
    }
    @objc private func changeDelay() {
        manager.holdDelay = (delaySlider.doubleValue * 20).rounded() / 20
        delaySlider.doubleValue = manager.holdDelay
        updateDelayLabel()
    }
    @objc private func toggleFrequency() { manager.frequencySorting = frequency.state == .on }
    @objc private func togglePanel() { manager.panelEnabled = enabled.state == .on }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AppSwitcherRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row), let column = tableColumn else { return nil }
        let app = filtered[row], binding = manager.bindings[app.id]
        let key = column.identifier
        if key.rawValue == "app" {
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? AppDragCell ?? AppDragCell()
            cell.identifier = key
            cell.draggable = canReorder && manager.isConfigured(app.id)
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 13)
                label.lineBreakMode = .byTruncatingMiddle
                let icon = NSImageView()
                for view in [label, icon] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 25),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                cell.textField = label; cell.imageView = icon
            }
            cell.textField?.stringValue = app.displayName
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: app.path)
            cell.toolTip = cell.draggable ? (AppLanguage.english ? "Drag to reorder · " : "拖拽调整顺序 · ") + app.path : (canReorder ? app.path : (AppLanguage.english ? "Clear search to drag" : "清空搜索后可拖拽排序"))
            cell.toolTip = (cell.toolTip ?? "") + (AppLanguage.english ? " · Switches: " : " · 切换次数：") + String(manager.switchCount(for: app.id))
            return cell
        }
        if key.rawValue == "alias" {
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = key
            let field: AppAliasField
            if let existing = cell.textField as? AppAliasField { field = existing }
            else {
                field = AppAliasField()
                field.translatesAutoresizingMaskIntoConstraints = false
                field.cell = AppAliasCell(textCell: "")
                field.isEditable = true; field.isSelectable = true
                field.font = .systemFont(ofSize: 12)
                field.isBezeled = true; field.bezelStyle = .roundedBezel
                field.focusRingType = .exterior; field.delegate = self
                field.placeholderString = AppLanguage.english ? "Use original name" : "使用原名称"
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    field.heightAnchor.constraint(equalToConstant: 28)
                ])
            }
            field.appID = app.id; field.stringValue = binding?.alias ?? ""
            field.setAccessibilityLabel(app.displayName + (AppLanguage.english ? " · Display alias" : " · 显示别名"))
            field.toolTip = AppLanguage.english ? "Return or leave to save; clear to restore the original name" : "回车或离开输入框保存；清空恢复原名称"
            return cell
        }
        if key.rawValue == "shortcut" {
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = key
            let recorder: SwitcherShortcutRecorder
            if let existing = cell.subviews.compactMap({ $0 as? SwitcherShortcutRecorder }).first { recorder = existing }
            else {
                recorder = SwitcherShortcutRecorder()
                recorder.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(recorder)
                NSLayoutConstraint.activate([
                    recorder.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    recorder.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    recorder.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    recorder.heightAnchor.constraint(equalToConstant: 28)
                ])
            }
            recorder.cancelRecording()
            recorder.identifier = key
            recorder.title = binding?.shortcut?.label ?? (AppLanguage.english ? "Click to record" : "点击录入快捷键")
            recorder.toolTip = AppLanguage.english ? "Press a shortcut · Esc cancels · Backspace clears" : "按下组合键 · Esc 取消 · Backspace 清除"
            recorder.setAccessibilityLabel(app.displayName + " · " + column.title)
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
            return cell
        }
        let cell = tableView.makeView(withIdentifier: key, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = key
        let button: NSButton
        if let existing = cell.subviews.compactMap({ $0 as? NSButton }).first { button = existing }
        else {
            button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            button.font = .systemFont(ofSize: 12)
            button.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
            ])
        }
        button.identifier = key; button.cell?.representedObject = app.id; button.target = self
        button.title = AppLanguage.english ? "Show" : "展示"
        button.state = binding?.showInPanel == true ? .on : .off; button.action = #selector(toggleApp(_:))
        button.toolTip = manager.failures[app.id] ?? app.path
        button.setAccessibilityLabel(app.displayName + " · " + column.title)
        return cell
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
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    var onRecord: ((ClipboardShortcut?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; target = self; action = #selector(beginRecording)
        font = .systemFont(ofSize: 12); alignment = .center
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : hovered ? 0.10 : 0.05).setFill(); shape.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); shape.lineWidth = 1; shape.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor, .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 10, y: (bounds.height - height) / 2, width: max(0, bounds.width - 20), height: height), withAttributes: attributes)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
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

@MainActor
private final class AppAliasField: NSTextField { var appID = "" }

@MainActor
private final class AppDragCell: NSTableCellView {
    var draggable = false { didSet { grip.isHidden = !draggable; window?.invalidateCursorRects(for: self) } }
    private let grip = NSImageView()
    private var hoverArea: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        grip.contentTintColor = .secondaryLabelColor; grip.alphaValue = 0.45
        grip.translatesAutoresizingMaskIntoConstraints = false; addSubview(grip)
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 13), grip.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func resetCursorRects() { super.resetCursorRects(); if draggable { addCursorRect(bounds, cursor: .openHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { grip.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { grip.alphaValue = 0.45 }
}

@MainActor
private final class AppAliasCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let font = font ?? .systemFont(ofSize: 12)
        let height = ceil(font.ascender - font.descender + font.leading)
        result.origin.y = rect.midY - height / 2
        result.size.height = height
        return result
    }
}

@MainActor
private final class AppSwitcherRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(hovered ? 0.065 : 0.025).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 7, yRadius: 7).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.15 : 0.09).setFill(); shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.65 : 0.35).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}
