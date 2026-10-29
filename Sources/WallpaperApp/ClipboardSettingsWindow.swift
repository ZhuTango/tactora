import AppKit
import ServiceManagement

@MainActor
final class ClipboardSettingsWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private var tabs: NSTabView?
    private var allSections: [NSTabViewItem] = []
    var onLidSleepChange: (() -> Void)?
    private let lidSleepToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onFeatureChange: ((ToolFeature, Bool) -> Void)?
    private var sectionPicker: NSSegmentedControl?
    private var backgroundMenu: NSMenu?
    private let backgroundActions = NSStackView()
    private let languagePicker = NSPopUpButton()
    private let loginToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    var onLanguageChange: (() -> Void)?
    private let loginAccess: LoginItemAccess
    private let store: ClipboardStore
    private let defaults: UserDefaults
    private let isTrusted: () -> Bool
    private let requestTrust: () -> Void
    private let retention = NSPopUpButton()
    private let shortcutButton = SettingsFeedbackButton()
    private var shortcutMonitor: Any?
    private var recordingShortcut = false
    private var shortcut = ClipboardShortcut.saved()
    var onShortcutChange: ((ClipboardShortcut) -> Bool)?
    private let recording = NSButton(checkboxWithTitle: AppLanguage.text("记录新的剪贴板内容"), target: nil, action: nil)
    private let directPaste = NSButton(checkboxWithTitle: AppLanguage.text("回车或双击时直接粘贴到原应用"), target: nil, action: nil)
    private let permission = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    var onClose: (() -> Void)?

    init(store: ClipboardStore, defaults: UserDefaults = .standard, loginAccess: LoginItemAccess? = nil,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         requestTrust: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         }) {
        self.store = store
        self.loginAccess = loginAccess ?? .system
        self.defaults = defaults
        self.isTrusted = isTrusted
        self.requestTrust = requestTrust
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppLanguage.text("剪贴板设置")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = content
        let title = NSTextField(labelWithString: AppLanguage.text("剪贴板设置"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: AppLanguage.text("管理记录方式、历史保留时间与粘贴行为。"))
        subtitle.textColor = .secondaryLabelColor
        recording.target = self; recording.action = #selector(changeRecording)
        retention.addItems(withTitles: [AppLanguage.text("7 天"), AppLanguage.text("30 天")])
        retention.target = self; retention.action = #selector(changeRetention)
        retention.setAccessibilityLabel(AppLanguage.text("历史保留时间"))
        let retentionRow = NSStackView(views: [NSTextField(labelWithString: AppLanguage.text("历史保留时间")), retention])
        retentionRow.orientation = .horizontal; retentionRow.spacing = 20
        shortcutButton.title = AppLanguage.text("录制快捷键…")
        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self; shortcutButton.action = #selector(recordShortcut)
        let reset = SettingsFeedbackButton(title: AppLanguage.text("恢复默认"), target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: AppLanguage.text("呼出快捷键")), shortcutButton, reset])
        shortcutRow.orientation = .horizontal; shortcutRow.spacing = 14
        directPaste.target = self; directPaste.action = #selector(changeDirectPaste)
        permission.toolTip = Bundle.main.bundleURL.path
        permission.font = .systemFont(ofSize: 11); permission.textColor = .secondaryLabelColor
        let capacity = NSTextField(wrappingLabelWithString: AppLanguage.text("缓存上限：1000 条记录，图片共 2560 MB。\n图片保存本地副本；文件仅保存引用，不复制原文件。\n固定项最多 200 条，不自动过期；容量优先保留固定项。"))
        capacity.font = .systemFont(ofSize: 12); capacity.textColor = .secondaryLabelColor
        let privacy = NSTextField(wrappingLabelWithString: AppLanguage.text("仅存储在本机。跳过系统标记为敏感的内容；没有敏感标记的内容仍可能被记录。"))
        privacy.font = .systemFont(ofSize: 11); privacy.textColor = .secondaryLabelColor
        let clear = SettingsFeedbackButton(title: AppLanguage.text("清空全部历史…"), target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let captureCard = settingsCard(AppLanguage.english ? "Capture & retention" : "记录与保留", [recording, retentionRow])
        let interactionCard = settingsCard(AppLanguage.english ? "Shortcuts & paste" : "快捷键与粘贴", [shortcutRow, directPaste, permission])
        let storageCard = settingsCard(AppLanguage.english ? "Local storage" : "本地存储", [capacity, privacy, clear])
        let stack = NSStackView(views: [title, subtitle, captureCard, interactionCard, storageCard, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            captureCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            interactionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            storageCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permission.widthAnchor.constraint(equalTo: interactionCard.widthAnchor, constant: -32),
            capacity.widthAnchor.constraint(equalTo: storageCard.widthAnchor, constant: -32),
            privacy.widthAnchor.constraint(equalTo: storageCard.widthAnchor, constant: -32),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func present() {
        refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        if !recordingShortcut { shortcutButton.title = shortcut.label + AppLanguage.text(" · 点击修改") }
        recording.state = store.enabled ? .on : .off
        recording.isEnabled = store.error == nil
        retention.selectItem(at: store.retentionDays == 30 ? 1 : 0)
        retention.isEnabled = store.error == nil
        directPaste.state = defaults.bool(forKey: "clipboardDirectPaste") ? .on : .off
        if isTrusted() {
            permission.stringValue = AppLanguage.text("辅助功能已授权。开启后可直接粘贴到原应用。")
        } else if directPaste.state == .on {
            permission.stringValue = AppLanguage.text("已选择开启，等待辅助功能授权，暂时仅复制。若已授权仍无效，请退出本应用，在系统设置中移除旧条目，重新添加当前版本，再打开应用。")
        } else {
            permission.stringValue = AppLanguage.text("直接粘贴需要 macOS 辅助功能授权。不开启也可复制后按 ⌘V。")
        }
        status.stringValue = store.error ?? (AppLanguage.english
            ? "\(store.entries.count) entries · " + (store.enabled ? "Recording" : "Paused")
            : "当前保存 \(store.entries.count) 条 · \(store.enabled ? "正在记录" : "已暂停记录")")
    }
    func windowWillClose(_ notification: Notification) { stopRecordingShortcut(); onClose?() }
    func windowDidBecomeKey(_ notification: Notification) { refresh(); refreshGeneral(); (tabs?.selectedTabViewItem?.view as? WindowManagerSettingsView)?.refresh() }
    func windowDidResignKey(_ notification: Notification) { stopRecordingShortcut() }
    @objc private func recordShortcut() {
        if recordingShortcut { stopRecordingShortcut(); return }
        recordingShortcut = true
        shortcutButton.title = AppLanguage.text("请按新快捷键…")
        status.stringValue = AppLanguage.text("按 ⌘ / ⌃ / ⌥ 与字母、数字或空格组合；Esc 取消。")
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.recordingShortcut else { return event }
            _ = self.captureShortcut(event)
            return nil
        }
    }
    @discardableResult func captureShortcut(_ event: NSEvent) -> Bool {
        guard recordingShortcut else { return false }
        if event.keyCode == 53 { stopRecordingShortcut(); return false }
        guard let value = ClipboardShortcut.from(event) else {
            status.stringValue = AppLanguage.text("请包含 ⌘、⌃ 或 ⌥，再加字母、数字或空格。")
            return false
        }
        stopRecordingShortcut()
        return applyShortcut(value)
    }
    private func stopRecordingShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
        recordingShortcut = false
        shortcutButton.title = shortcut.label + AppLanguage.text(" · 点击修改")
    }
    @objc private func resetShortcut() { stopRecordingShortcut(); _ = applyShortcut(.defaultValue) }
    private func applyShortcut(_ value: ClipboardShortcut) -> Bool {
        guard onShortcutChange?(value) == true else {
            status.stringValue = AppLanguage.text("无法注册此快捷键，可能已被占用；已保留原快捷键。")
            return false
        }
        shortcut = value
        shortcutButton.title = value.label + AppLanguage.text(" · 点击修改")
        status.stringValue = AppLanguage.text("呼出快捷键已保存为 ") + value.label
        return true
    }
    @objc private func changeRecording() {
        do { try store.setEnabled(recording.state == .on); refresh() }
        catch { showError(error); refresh() }
    }
    @objc private func changeRetention() {
        do { try store.setRetentionDays(retention.indexOfSelectedItem == 1 ? 30 : 7); refresh() }
        catch { showError(error); refresh() }
    }
    @objc private func changeDirectPaste() {
        let enabled = directPaste.state == .on
        defaults.set(enabled, forKey: "clipboardDirectPaste")
        if enabled && !isTrusted() { requestTrust() }
        refresh()
    }
    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = AppLanguage.text("清空全部剪贴板历史？")
        alert.informativeText = AppLanguage.text("删除所有历史（包括固定项）和缓存图片，原文件与系统当前剪贴板不受影响。")
        alert.addButton(withTitle: AppLanguage.text("清空历史")); alert.addButton(withTitle: AppLanguage.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.clear(); refresh() } catch { showError(error) }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = AppLanguage.text("无法保存剪贴板设置"); alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func configureUnified(backgroundMenu: NSMenu, appSwitcher: AppSwitcher? = nil, windowManager: WindowManager? = nil, keepAwake: KeepAwake? = nil) {
        guard tabs == nil, let window, let clipboardView = window.contentView else { return }
        self.backgroundMenu = backgroundMenu
        window.appearance = NSAppearance(named: .darkAqua)
        clipboardView.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        window.title = AppLanguage.text("设置") + " · " + AppLanguage.text("轻工具")
        window.setContentSize(NSSize(width: 820, height: 680))
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        let tabs = NSTabView()
        tabs.wantsLayer = true
        tabs.tabViewType = .noTabsNoBorder
        let navigation = NSSegmentedControl(labels: [AppLanguage.text("通用"), AppLanguage.text("剪贴板"), AppLanguage.text("桌面背景")] + (appSwitcher == nil ? [] : [AppLanguage.english ? "Apps" : "应用切换"]), trackingMode: .selectOne, target: self, action: #selector(sectionChanged(_:)))
        navigation.wantsLayer = true
        navigation.selectedSegment = 0
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sectionPicker = navigation
        root.addSubview(navigation)
        self.tabs = tabs
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            navigation.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            navigation.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            navigation.widthAnchor.constraint(equalToConstant: windowManager != nil ? 680 : appSwitcher == nil ? 360 : 520),
            tabs.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        for (id, title, view) in [("general", AppLanguage.text("通用"), makeGeneralView()),
                                   ("clipboard", AppLanguage.text("剪贴板"), clipboardView),
                                   ("wallpaper", AppLanguage.text("桌面背景"), makeBackgroundView())] {
            let item = NSTabViewItem(identifier: id)
            item.label = AppLanguage.text(title); item.view = view
            tabs.addTabViewItem(item)
        }
        if let appSwitcher {
            let item = NSTabViewItem(identifier: "apps")
            item.label = AppLanguage.english ? "Apps" : "应用切换"
            item.view = AppSwitcherSettingsView(manager: appSwitcher)
            tabs.addTabViewItem(item)
        }
        if let windowManager {
            let item = NSTabViewItem(identifier: "windows")
            item.label = AppLanguage.english ? "Windows" : "窗口管理"
            item.view = WindowManagerSettingsView(manager: windowManager)
            tabs.addTabViewItem(item)
        }
        if let keepAwake {
            let item = NSTabViewItem(identifier: "awake")
            item.label = AppLanguage.english ? "Keep Awake" : "防止休眠"
            item.view = KeepAwakeSettingsView(manager: keepAwake)
            tabs.addTabViewItem(item)
        }
        window.contentView = root
        tabs.delegate = self
        tabs.selectTabViewItem(at: 0)
        allSections = tabs.tabViewItems
        refreshFeatureSections()
        refreshGeneral()
    }
    @objc private func sectionChanged(_ sender: NSSegmentedControl) { tabs?.selectTabViewItem(at: sender.selectedSegment) }
    func selectSection(_ id: String) {
        let target = tabs?.tabViewItems.first { $0.identifier as? String == id }
            ?? tabs?.tabViewItems.first
        if let target { tabs?.selectTabViewItem(target) }
    }
    private func refreshFeatureSections() {
        guard let tabs, let picker = sectionPicker else { return }
        let selected = tabs.selectedTabViewItem?.identifier as? String ?? "general"
        let visible = allSections.filter { item in
            guard let id = item.identifier as? String, let feature = ToolFeature(rawValue: id) else { return true }
            return feature.isEnabled(in: defaults)
        }
        tabs.delegate = nil
        for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
        for item in visible { tabs.addTabViewItem(item) }
        picker.segmentCount = visible.count
        for (index, item) in visible.enumerated() { picker.setLabel(item.label, forSegment: index) }
        tabs.delegate = self
        selectSection(selected)
    }
    @objc private func changeFeature(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue.replacingOccurrences(of: "toolEnabled.", with: ""),
              let feature = ToolFeature(rawValue: raw) else { return }
        let enabled = sender.state == .on
        feature.setEnabled(enabled, in: defaults)
        stopRecordingShortcut()
        onFeatureChange?(feature, enabled)
        refreshFeatureSections()
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        stopRecordingShortcut()
        if let tabViewItem { sectionPicker?.selectedSegment = tabView.indexOfTabViewItem(tabViewItem) }
        refreshGeneral()
        if tabViewItem?.identifier as? String == "wallpaper" { rebuildBackground() }
        (tabViewItem?.view as? WindowManagerSettingsView)?.refresh()
    }
    private func form(_ views: [NSView]) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24)
        ])
        for view in views where view is SettingsGroupCard {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return root
    }
    private func makeGeneralView() -> NSView {
        let heading = NSTextField(labelWithString: AppLanguage.text("通用"))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        languagePicker.addItems(withTitles: [AppLanguage.english ? "Follow System" : AppLanguage.text("跟随系统"), AppLanguage.text("简体中文"), "English"])
        languagePicker.selectItem(at: ["system", "zh-Hans", "en"].firstIndex(of: AppLanguage.selection) ?? 0)
        languagePicker.target = self; languagePicker.action = #selector(changeLanguage)
        languagePicker.setAccessibilityLabel(AppLanguage.english ? "Interface language" : AppLanguage.text("界面语言"))
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Language" : AppLanguage.text("界面语言")), languagePicker])
        row.spacing = 20
        loginToggle.title = AppLanguage.english ? "Launch at login" : AppLanguage.text("登录 Mac 时自动启动")
        loginToggle.target = self; loginToggle.action = #selector(changeLogin)
        loginStatus.textColor = .secondaryLabelColor
        let systemSettings = SettingsFeedbackButton(title: AppLanguage.english ? "Open Login Items Settings…" : AppLanguage.text("打开系统登录项设置…"), target: self, action: #selector(openLoginSettings))
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Changes are saved automatically. Wallpaper and clipboard preferences are in the tabs above."
            : AppLanguage.text("设置自动保存。桌面背景与剪贴板设置统一在上方分页中，后续工具也会加入这里。"))
        note.textColor = .secondaryLabelColor
        lidSleepToggle.title = AppLanguage.english ? "Black out built-in display when lid closes" : "合盖遮黑内屏"
        lidSleepToggle.identifier = NSUserInterfaceItemIdentifier(LidSleepPolicy.preferenceKey)
        lidSleepToggle.target = self
        lidSleepToggle.action = #selector(changeLidSleep)
        let lidNote = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Cover the built-in screen with black while closed; uncover on opening. External screens and system sleep settings stay unchanged. Backlight may remain on. Mirrored displays are excluded."
            : "合盖时用纯黑遮住内屏，开盖恢复；不影响外屏、不主动休眠。黑色画面不等于关闭背光；镜像显示时不启用遮罩。")
        lidNote.textColor = .secondaryLabelColor
        lidNote.font = .systemFont(ofSize: 11)
        let language = settingsCard(AppLanguage.english ? "Language" : "语言", [row])
        let lidBehavior = settingsCard(AppLanguage.english ? "Lid Behavior" : "合盖行为", [lidSleepToggle, lidNote])
        lidNote.widthAnchor.constraint(equalTo: lidBehavior.widthAnchor, constant: -32).isActive = true
        let startup = settingsCard(AppLanguage.english ? "Startup" : "启动", [loginToggle, loginStatus, systemSettings])
        loginStatus.widthAnchor.constraint(equalTo: startup.widthAnchor, constant: -32).isActive = true
        let featureButtons = ToolFeature.allCases.map { feature -> NSView in
            let title: String
            switch feature {
            case .clipboard: title = AppLanguage.text("剪贴板")
            case .wallpaper: title = AppLanguage.text("桌面背景")
            case .apps: title = AppLanguage.english ? "App Switcher" : "应用切换"
            case .awake: title = AppLanguage.english ? "Keep Awake" : "防止休眠"
            case .windows: title = AppLanguage.english ? "Windows" : "窗口管理"
            }
            let symbols: [ToolFeature: String] = [.clipboard: "doc.on.clipboard", .wallpaper: "photo", .apps: "square.stack.3d.up", .windows: "macwindow", .awake: "cup.and.saucer"]
            let row = SettingsToolRow(title: title, symbol: symbols[feature]!, target: self, action: #selector(changeFeature(_:)))
            row.toggle.identifier = NSUserInterfaceItemIdentifier("toolEnabled." + feature.rawValue)
            row.toggle.state = feature.isEnabled(in: defaults) ? .on : .off
            return row
        }
        let featureNote = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Disabled tools disappear from menus and stop running. Their settings are kept."
            : "关闭后隐藏入口并停用功能，保留原配置。背景关闭后保留当前静态壁纸。")
        featureNote.textColor = .secondaryLabelColor
        let featureGrid = SettingsFeatureGrid(items: featureButtons)
        let featureSearch = NSSearchField()
        featureSearch.placeholderString = AppLanguage.english ? "Find a tool" : "搜索工具"
        featureSearch.setAccessibilityLabel(featureSearch.placeholderString)
        featureSearch.sendsSearchStringImmediately = true
        featureSearch.delegate = featureGrid
        featureSearch.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let features = settingsCard(AppLanguage.english ? "Tools" : "工具管理", [featureGrid, featureNote], accessory: featureSearch)
        featureSearch.widthAnchor.constraint(equalToConstant: 180).isActive = true
        featureNote.font = .systemFont(ofSize: 11)
        featureGrid.widthAnchor.constraint(equalTo: features.widthAnchor, constant: -32).isActive = true
        featureNote.widthAnchor.constraint(equalTo: features.widthAnchor, constant: -32).isActive = true
        return form([heading, features, language, lidBehavior, startup])
    }
    @objc private func changeLanguage() {
        AppLanguage.selection = ["system", "zh-Hans", "en"][languagePicker.indexOfSelectedItem]
        onLanguageChange?()
    }
    @objc private func changeLidSleep() {
        defaults.set(lidSleepToggle.state == .on, forKey: LidSleepPolicy.preferenceKey)
        onLidSleepChange?()
    }
    private func refreshGeneral() {
        lidSleepToggle.state = defaults.bool(forKey: LidSleepPolicy.preferenceKey) ? .on : .off
        guard tabs != nil else { return }
        let status = loginAccess.status()
        loginToggle.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        loginToggle.allowsMixedState = true
        switch status {
        case .enabled: loginStatus.stringValue = AppLanguage.english ? "Enabled in macOS Login Items." : AppLanguage.text("已启用，将在登录 Mac 时启动。")
        case .requiresApproval: loginStatus.stringValue = AppLanguage.english ? "Waiting for approval in System Settings → Login Items." : AppLanguage.text("等待系统批准，请在系统设置 → 登录项中允许轻工具。")
        case .notRegistered: loginStatus.stringValue = AppLanguage.english ? "Disabled." : AppLanguage.text("未启用开机启动。")
        case .notFound: loginStatus.stringValue = AppLanguage.english ? "App not available to the login service. Keep the app in its installed location." : AppLanguage.text("登录项服务未找到此应用，请保留应用的安装位置。")
        @unknown default: loginStatus.stringValue = AppLanguage.english ? "Unknown system status." : AppLanguage.text("无法确定系统状态。")
        }
    }
    @objc private func changeLogin() {
        do {
            if loginAccess.status() == .enabled || loginAccess.status() == .requiresApproval {
                try loginAccess.unregister()
            } else { try loginAccess.register() }
            refreshGeneral()
        } catch {
            refreshGeneral()
            loginStatus.stringValue = (AppLanguage.english ? "Could not change login item: " : AppLanguage.text("无法修改登录项：")) + error.localizedDescription
        }
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func makeBackgroundView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        backgroundActions.wantsLayer = true
        backgroundActions.orientation = .vertical
        backgroundActions.alignment = .leading
        backgroundActions.spacing = 10
        backgroundActions.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backgroundActions)
        NSLayoutConstraint.activate([
            backgroundActions.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            backgroundActions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            backgroundActions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24)
        ])
        return root
    }
    func refreshBackground(_ menu: NSMenu) {
        backgroundMenu = menu
        if tabs?.selectedTabViewItem?.identifier as? String == "wallpaper" { rebuildBackground() }
    }
    private func rebuildBackground() {
        guard let backgroundMenu else { return }
        backgroundActions.arrangedSubviews.forEach { backgroundActions.removeArrangedSubview($0); $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: AppLanguage.text("桌面背景"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        backgroundActions.addArrangedSubview(title)
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.text("适用于所有屏幕和以后选择的背景。各屏幕的文件与播放操作请使用菜单栏。"))
        hint.textColor = .secondaryLabelColor
        backgroundActions.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: backgroundActions.widthAnchor).isActive = true
        guard let preferences = backgroundMenu.items.first(where: { $0.identifier?.rawValue == "wallpaperPreferences" })?.submenu else { return }
        let headings = AppLanguage.english ? ["Video quality", "Loop playback", "Energy saving"] : ["视频画质", "循环播放", "节能"]
        var groups: [[NSMenuItem]] = [[]]
        for item in preferences.items {
            if item.isSeparatorItem { groups.append([]) }
            else { groups[groups.count - 1].append(item) }
        }
        for (index, items) in groups.enumerated() {
            let buttons = items.filter { $0.action != nil }.map { item -> NSView in
                let button = SettingsFeedbackButton(title: (item.state == .on ? "✓ " : "") + item.title, target: self, action: #selector(backgroundAction(_:)))
                button.selectedStyle = item.state == .on
                button.isEnabled = item.isEnabled
                button.cell?.representedObject = item
                return button
            }
            let card = settingsCard(headings[min(index, 2)], buttons)
            backgroundActions.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: backgroundActions.widthAnchor).isActive = true
            for button in buttons { button.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true }
        }
    }

    @objc private func backgroundAction(_ sender: NSButton) {
        guard let item = sender.cell?.representedObject as? NSMenuItem, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

}

@MainActor
private func settingsCard(_ title: String, _ views: [NSView], accessory: NSView? = nil) -> SettingsGroupCard {
    let card = SettingsGroupCard()
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 12, weight: .semibold)
    heading.textColor = .secondaryLabelColor
    let header: NSView
    if let accessory {
        let spacer = NSView()
        let row = NSStackView(views: [heading, spacer, accessory])
        row.orientation = .horizontal
        header = row
    } else { header = heading }
    let stack = NSStackView(views: [header] + views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    if accessory != nil { header.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true }
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
        stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
        stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
    ])
    return card
}

@MainActor
private final class SettingsGroupCard: NSView {
    private var hoverArea: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor }
}

@MainActor
final class SettingsFeedbackButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var hovered = false
    var titleHorizontalInset: CGFloat = 10
    var selectedStyle = false { didSet { updateSurface() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = SettingsFeedbackCell(textCell: "")
        setButtonType(.momentaryPushIn)
        isEnabled = true
        contentTintColor = .labelColor
        wantsLayer = true
        isBordered = false
        focusRingType = .exterior
        font = .systemFont(ofSize: 13, weight: .medium)
        alignment = .left
        layer?.cornerRadius = 7
        heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        updateSurface()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 20, height: max(30, size.height))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateSurface() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateSurface() }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateSurface(pressed: flag) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    fileprivate func updateSurface(pressed: Bool = false) {
        let color = selectedStyle ? NSColor.controlAccentColor : NSColor.white
        let opacity: CGFloat = pressed ? 0.3 : hovered && isEnabled ? 0.17 : selectedStyle ? 0.20 : 0.06
        CATransaction.begin()
        CATransaction.setDisableActions(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = color.withAlphaComponent(opacity).cgColor
        layer?.borderWidth = selectedStyle ? 1 : 0
        layer?.borderColor = color.withAlphaComponent(0.55).cgColor
        CATransaction.commit()
    }
}

@MainActor
private final class SettingsFeedbackCell: NSButtonCell {
    override var isHighlighted: Bool {
        didSet { (controlView as? SettingsFeedbackButton)?.updateSurface(pressed: isHighlighted) }
    }
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.insetBy(dx: (controlView as? SettingsFeedbackButton)?.titleHorizontalInset ?? 10, dy: 0), in: controlView)
    }
}


/// Bounded three-column tool picker: additional tools scroll inside the section.
@MainActor
final class SettingsFeatureGrid: NSScrollView, NSSearchFieldDelegate {
    private var query = ""
    private var visibleItems: [NSView] { items.filter { query.isEmpty || (($0 as? SettingsToolRow)?.title ?? ($0 as? NSButton)?.title ?? "").localizedCaseInsensitiveContains(query) } }
    func filter(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        contentView.scroll(to: .zero)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField { filter(field.stringValue) }
    }
    private let items: [NSView]
    private let content = SettingsFeatureGridContent()
    init(items: [NSView]) {
        self.items = items
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = content
        for item in items { content.addSubview(item) }
        let rows = max(1, (items.count + 2) / 3)
        heightAnchor.constraint(equalToConstant: CGFloat(min(3, rows) * 36)).isActive = true
        setAccessibilityLabel(AppLanguage.english ? "Tool switches" : "功能开关")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        let visible = visibleItems
        let rows = max(1, (visible.count + 2) / 3)
        content.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows * 36))
        let cellWidth = max(0, (width - 24) / 3)
        for item in items { item.isHidden = !visible.contains { $0 === item } }
        for (index, item) in visible.enumerated() {
            item.frame = NSRect(x: CGFloat(index % 3) * (cellWidth + 12),
                                y: CGFloat(index / 3) * 36, width: cellWidth, height: 36)
        }
    }
}

@MainActor
private final class SettingsFeatureGridContent: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsToolRow: NSView {
    let title: String
    let toggle = NSSwitch()
    private var tracking: NSTrackingArea?
    init(title: String, symbol: String, target: AnyObject, action: Selector) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        toggle.controlSize = .small
        toggle.target = target; toggle.action = action
        toggle.setAccessibilityLabel(title)
        toggle.toolTip = AppLanguage.english ? "Enable or disable; settings are kept" : "启用或停用，保留原配置"
        for view in [icon, label, toggle] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}
