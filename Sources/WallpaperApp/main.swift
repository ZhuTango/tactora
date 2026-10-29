import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: WallpaperController!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let backgroundMenu = NSMenu()
    private var clipboard: ClipboardStore!
    private var clipboardWindow: ClipboardWindow?
    private var clipboardSettings: ClipboardSettingsWindow?
    private let clipboardShortcut = GlobalClipboardShortcut()
    private var shortcutRegistered = false
    private var appSwitcher: AppSwitcher!
    private let windowManager = WindowManager()
    private let lidDisplaySleep = LidDisplaySleep()
    private let keepAwake = KeepAwake()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var selections: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) { NSApp.terminate(nil); return }
        do {
            controller = try WallpaperController(automaticallyPauseWhenOccluded:
                UserDefaults.standard.object(forKey: "pauseWhenCovered") as? Bool ?? true)
            try controller.migrateLegacy(defaults: .standard)
        } catch {
            showError(error)
            NSApp.terminate(nil)
            return
        }
        keepAwake.onChange = { [weak self] in self?.updateMenu() }
        lidDisplaySleep.refresh()
        clipboard = ClipboardStore()
        clipboard.onChange = { [weak self] in self?.clipboardWindow?.refresh(); self?.clipboardSettings?.refresh(); self?.updateMenu() }
        clipboard.setSuspended(!ToolFeature.clipboard.isEnabled())
        clipboard.start()
        clipboardShortcut.action = { [weak self] in self?.showClipboard() }
        shortcutRegistered = ToolFeature.clipboard.isEnabled() && clipboardShortcut.register()
        appSwitcher = AppSwitcher(start: ToolFeature.apps.isEnabled())
        appSwitcher.setFeatureEnabled(ToolFeature.apps.isEnabled())
        windowManager.conflicts = { [weak self] value in
            let clipboard = ClipboardShortcut.saved()
            return (clipboard.keyCode == value.keyCode && clipboard.modifiers == value.modifiers)
                || self?.appSwitcher.bindings.values.contains(where: { $0.shortcut?.keyCode == value.keyCode && $0.shortcut?.modifiers == value.modifiers }) == true
        }
        windowManager.setEnabled(ToolFeature.windows.isEnabled())
        controller.setFeatureEnabled(ToolFeature.wallpaper.isEnabled())
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = ToolIcon.statusImage(awake: false)
        statusItem.button?.toolTip = "轻工具 · 背景与剪贴板"
        menu.delegate = self
        statusItem.menu = menu
        controller.policy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        controller.onChange = { [weak self] in self?.updateMenu() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.controller.policy.displayAsleep = true }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { $0.controller.policy.displayAsleep = false; $0.lidDisplaySleep.displaysDidWake() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.controller.policy.systemAsleep = true }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.controller.policy.systemAsleep = false; $0.keepAwake.expireIfNeeded() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.controller.policy.sessionInactive = true }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { $0.controller.policy.sessionInactive = false }
        observe(.default, .NSProcessInfoPowerStateDidChange) {
            $0.controller.policy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshDisplays(); $0.lidDisplaySleep.displaysChanged() }
        refreshDisplays()
        if let url = pendingOpenURLs.last { openFile(url); pendingOpenURLs.removeAll() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--request-accessibility") {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            showWindowSettings()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (AppDelegate) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
                self.clipboard?.setSuspended(!ToolFeature.clipboard.isEnabled() || self.controller.policy.displayAsleep || self.controller.policy.systemAsleep || self.controller.policy.sessionInactive)
                self.updateMenu()
            }
        }
        observers.append((center, token))
    }

    private func refreshDisplays() {
        refreshTask?.cancel()
        guard ToolFeature.wallpaper.isEnabled() else { return }
        refreshTask = Task { [weak self] in await self?.controller.refreshDisplays() }
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    private func updateMenu() {
        guard controller != nil, clipboard != nil else { return }
        let awake = ToolFeature.awake.isEnabled() && keepAwake.active
        statusItem?.button?.image = ToolIcon.statusImage(awake: awake)
        statusItem?.button?.toolTip = awake ? "轻工具 · " + keepAwake.status : "轻工具 · 防休眠未开启"
        statusItem?.button?.setAccessibilityLabel(awake ? "轻工具 · 防休眠已开启" : "轻工具 · 防休眠未开启")
        backgroundMenu.removeAllItems()
        backgroundMenu.autoenablesItems = false
        add("轻壁纸 · 每屏独立背景", to: backgroundMenu)
        add("配置自动保存，重启与重连后恢复", to: backgroundMenu)
        backgroundMenu.addItem(.separator())
        let connected = DisplayTarget.connected()
        for (index, display) in connected.enumerated() {
            addDisplay(id: display.id, title: "屏幕 \(index + 1) · \(display.name)", online: true)
        }
        if connected.isEmpty { add("未检测到可配置的屏幕", to: backgroundMenu) }
        backgroundMenu.addItem(.separator())
        let hasVideo = controller.configurations.values.contains { $0.kind == .video || $0.playlist != nil }
        let stop = add("停止全部视频与轮换", to: backgroundMenu, action: #selector(stopAll))
        stop.isEnabled = hasVideo || !selections.isEmpty
        add("休眠 / 低电量模式自动停播", to: backgroundMenu)
        let pause = add("桌面被遮挡时自动暂停", to: backgroundMenu, action: #selector(toggleAutomaticPause))
        pause.state = (UserDefaults.standard.object(forKey: "pauseWhenCovered") as? Bool ?? true) ? .on : .off
        let preferences = add("背景通用配置", to: backgroundMenu)
        preferences.isEnabled = true
        preferences.identifier = NSUserInterfaceItemIdentifier("wallpaperPreferences")
        let options = NSMenu()
        options.autoenablesItems = false
        preferences.submenu = options
        for quality in VideoQuality.allCases {
            let item = add(quality.title, to: options, action: #selector(changeGlobalQuality(_:)))
            item.representedObject = quality.rawValue
            item.state = (UserDefaults.standard.string(forKey: "wallpaperQuality") ?? "original") == quality.rawValue ? .on : .off
        }
        options.addItem(.separator())
        for mode in VideoLoopMode.allCases {
            let item = add(mode.title, to: options, action: #selector(changeGlobalLoop(_:)))
            item.representedObject = mode.rawValue
            item.state = (UserDefaults.standard.string(forKey: "wallpaperLoop") ?? "efficient") == mode.rawValue ? .on : .off
        }
        options.addItem(.separator())
        options.addItem(pause.copy() as! NSMenuItem)
        backgroundMenu.addItem(.separator())
        self.menu.removeAllItems()
        self.menu.autoenablesItems = false
        if ToolFeature.clipboard.isEnabled() {
        add(shortcutRegistered ? AppLanguage.text("剪贴板列表…") + "  " + ClipboardShortcut.saved().label : "剪贴板列表…（快捷键被占用）", to: self.menu, action: #selector(showClipboard))
        self.menu.addItem(.separator())
        }
        if ToolFeature.awake.isEnabled() {
            let entry = NSMenuItem(title: keepAwake.active ? (AppLanguage.english ? "Keep Awake · On" : "防休眠 · 已开启") : (AppLanguage.english ? "Keep Awake · Off" : "防休眠 · 未开启"), action: nil, keyEquivalent: "")
            entry.state = keepAwake.active ? .on : .off
            entry.image = NSImage(systemSymbolName: keepAwake.active ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: nil)
            let submenu = NSMenu(); submenu.autoenablesItems = false
            entry.submenu = submenu; self.menu.addItem(entry)
            add(keepAwake.status, to: submenu)
            if keepAwake.active {
                let summary = add(keepAwake.status, to: self.menu)
                summary.indentationLevel = 1
                add(AppLanguage.english ? "Stop Keep Awake" : "停止防休眠", to: self.menu, action: #selector(stopKeepAwake))
            }
            for minutes in keepAwake.durations + [0] {
                let item = NSMenuItem(title: KeepAwake.label(minutes), action: #selector(startKeepAwake(_:)), keyEquivalent: "")
                item.target = self; item.tag = minutes
                item.state = keepAwake.active && keepAwake.selectedMinutes == minutes ? .on : .off
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            if keepAwake.active { add(AppLanguage.english ? "Stop" : "停止防休眠", to: submenu, action: #selector(stopKeepAwake)) }
            add(AppLanguage.english ? "Custom durations…" : "自定义时长…", to: submenu, action: #selector(showKeepAwakeSettings))
        }
        if ToolFeature.awake.isEnabled() { self.menu.addItem(.separator()) }
        let quickActions: Set<Selector> = [#selector(chooseFiles(_:)), #selector(nextBackground(_:)),
            #selector(toggleRotation(_:)), #selector(stop(_:)), #selector(resume(_:)), #selector(clear(_:))]
        for display in backgroundMenu.items where ToolFeature.wallpaper.isEnabled() && display.submenu != nil && display.identifier == nil {
            guard let source = display.submenu else { continue }
            let parent = add(display.title.components(separatedBy: " · ").prefix(2).joined(separator: " · "), to: self.menu)
            parent.isEnabled = true
            let quick = NSMenu()
            quick.autoenablesItems = false
            parent.submenu = quick
            if let status = source.items.first {
                // Keep status visible without opening a submenu; retain the full filename in the tooltip.
                let summary = add(status.title, to: self.menu)
                summary.indentationLevel = 1
                summary.toolTip = status.title
                summary.title = status.title.count > 72 ? String(status.title.prefix(69)) + "…" : status.title
                quick.addItem(status.copy() as! NSMenuItem)
                quick.addItem(.separator())
            }
            for item in source.items {
                if item.submenu != nil || (item.action.map { quickActions.contains($0) } ?? false) {
                    quick.addItem(item.copy() as! NSMenuItem)
                }
            }
            quick.addItem(.separator())
            add("背景详细设置…", to: quick, action: #selector(showWallpaperSettings))
        }
        if ToolFeature.wallpaper.isEnabled() && connected.isEmpty { add("未检测到可配置的屏幕", to: self.menu) }
        self.menu.addItem(.separator())
        if ToolFeature.apps.isEnabled() { add(AppLanguage.english ? "App Switcher…" : "应用切换…", to: self.menu, action: #selector(showAppSwitcherSettings)) }
        if ToolFeature.windows.isEnabled() { add(AppLanguage.english ? "Window Management…" : "窗口管理…", to: self.menu, action: #selector(showWindowSettings)) }
        add("设置…", to: self.menu, action: #selector(showSettings), key: ",")
        self.menu.addItem(.separator())
        add("关于轻工具", to: self.menu, action: #selector(about))
        add("退出", to: self.menu, action: #selector(quit), key: "q")
        clipboardSettings?.refreshBackground(backgroundMenu)
    }

    private func addDisplay(id: String, title: String, online: Bool) {
        let parent = add(title, to: backgroundMenu, id: id)
        parent.isEnabled = true
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        parent.submenu = submenu
        let config = controller.configurations[id]
        let description: String
        if controller.preparing.contains(id) { description = "正在生成低耗副本（首次需要片刻）…" }
        else if selections[id] != nil { description = "正在读取文件…" }
        else if let error = controller.errors[id] { description = "无法加载：\(error)" }
        else if let config {
            let state: String
            if !online { state = "已保存，等待连接" }
            else if config.kind == .photo { state = "照片" }
            else if config.stopped { state = "视频已停止" }
            else if controller.isDesktopHidden(id) { state = "桌面被遮挡，已暂停" }
            else if controller.isPlaying(id) { state = "视频播放中" }
            else if controller.policy.lowPowerMode { state = "低电量模式已停播" }
            else { state = "视频待恢复" }
            description = "\(state) · \(config.url.lastPathComponent)"
        } else { description = "使用系统当前背景" }
        add(description, to: submenu).toolTip = description
        submenu.addItem(.separator())
        if online {
            add("选择背景文件…（可多选图片和视频）", to: submenu, action: #selector(chooseFiles(_:)), id: id)
            if let config, let items = config.playlist, items.count > 1 {
                add("背景列表 · 第 \( (config.playlistIndex ?? 0) + 1)/\(items.count) 项", to: submenu)
                add("下一项", to: submenu, action: #selector(nextBackground(_:)), id: id)
                let toggle = add("自动轮换", to: submenu, action: #selector(toggleRotation(_:)), id: id)
                toggle.state = config.rotationEnabled != false ? .on : .off
                let parent = add("切换间隔 · \(Int(config.effectiveInterval)) 秒", to: submenu)
                parent.isEnabled = true
                let intervals = NSMenu()
                intervals.autoenablesItems = false
                parent.submenu = intervals
                for seconds in [30, 60, 300, 900, 1800, 3600] {
                    let label = seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
                    let item = add(label, to: intervals, action: #selector(changeInterval(_:)))
                    item.representedObject = ["id": id, "seconds": String(seconds)]
                    item.state = config.effectiveInterval == Double(seconds) ? .on : .off
                }
                add("自定义秒数…", to: intervals, action: #selector(customInterval(_:)), id: id)
            }
            if let config, config.kind == .video {
                submenu.addItem(.separator())
                for quality in VideoQuality.allCases {
                    let item = add(quality.title, to: submenu, action: #selector(changeQuality(_:)), id: id)
                    item.representedObject = ["id": id, "value": quality.rawValue]
                    item.state = config.effectiveQuality == quality ? .on : .off
                }
                submenu.addItem(.separator())
                for mode in VideoLoopMode.allCases {
                    let item = add(mode.title, to: submenu, action: #selector(changeLoopMode(_:)), id: id)
                    item.representedObject = ["id": id, "value": mode.rawValue]
                    item.state = config.effectiveLoopMode == mode ? .on : .off
                }
                submenu.addItem(.separator())
            }
            if config?.kind == .video || config?.playlist != nil || selections[id] != nil {
                let stopped = config?.stopped == true && selections[id] == nil
                add(stopped ? "恢复此屏背景" : "停止此屏视频与轮换", to: submenu,
                    action: stopped ? #selector(resume(_:)) : #selector(stop(_:)), id: id)
                if controller.errors[id] != nil {
                    add("重新加载此屏视频", to: submenu, action: #selector(resume(_:)), id: id)
                }
            }
        }
        if config != nil {
            submenu.addItem(.separator())
            add("清除此屏配置（保留系统壁纸）", to: submenu, action: #selector(clear(_:)), id: id)
        }
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, id: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: AppLanguage.text(title), action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = id
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }


    @objc private func chooseFiles(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.title = "选择背景文件"
        panel.message = "可同时选择图片和视频，自动识别类型。按列表顺序定时轮换；视频在间隔内循环，到时切换。"
        panel.allowedContentTypes = [.image, .movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "应用并保存"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        runOperation(for: id) { [controller] in try await controller!.selectFiles(urls, for: id) }
    }

    @objc private func nextBackground(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runOperation(for: id) { [controller] in try await controller!.advance(for: id) }
    }

    @objc private func toggleRotation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do { try controller.setRotation(for: id, enabled: controller.configurations[id]?.rotationEnabled == false) }
        catch { showError(error) }
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let id = info["id"],
              let seconds = Double(info["seconds"] ?? "") else { return }
        do { try controller.setRotation(for: id, interval: seconds) }
        catch { showError(error) }
    }

    @objc private func customInterval(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = AppLanguage.english ? "Rotation Interval" : "设置切换间隔"
        alert.informativeText = "输入 10 到 86400 秒。视频到时切换，不等待整段播完。"
        let field = NSTextField(string: String(Int(controller.configurations[id]?.effectiveInterval ?? 300)))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try controller.setRotation(for: id, interval: Double(field.stringValue) ?? .nan) }
        catch { showError(error) }
    }

    private func select(_ url: URL, kind: DisplayConfiguration.Kind, id: String) {
        runOperation(for: id) { [controller] in try await controller!.select(url, kind: kind, for: id) }
    }

    private func runOperation(for id: String, operation: @escaping @MainActor () async throws -> Void) {
        guard ToolFeature.wallpaper.isEnabled() else { return }
        selections[id]?.cancel()
        let generation = UUID()
        generations[id] = generation
        selections[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generations[id] == generation {
                    selections.removeValue(forKey: id)
                    generations.removeValue(forKey: id)
                    updateMenu()
                }
            }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError {}
            catch { if generations[id] == generation { showError(error) } }
        }
        updateMenu()
    }

    @objc private func stop(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runOperation(for: id) { [controller] in try await controller!.setStopped(true, for: id) }
    }

    @objc private func resume(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runOperation(for: id) { [controller] in try await controller!.setStopped(false, for: id) }
    }

    @objc private func clear(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runOperation(for: id) { [controller] in try await controller!.removeConfiguration(for: id) }
    }

    @objc private func changeGlobalQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = VideoQuality(rawValue: raw) else { return }
        runOperation(for: "preferences") { [controller] in
            try await controller!.setGlobalOptions(quality: value)
        }
    }
    @objc private func changeGlobalLoop(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = VideoLoopMode(rawValue: raw) else { return }
        runOperation(for: "preferences") { [controller] in
            try await controller!.setGlobalOptions(loopMode: value)
        }
    }

    @objc private func changeQuality(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? [String: String], let id = selection["id"],
              let value = selection["value"], let quality = VideoQuality(rawValue: value) else { return }
        runOperation(for: id) { [controller] in try await controller!.setOptions(for: id, quality: quality) }
    }

    @objc private func changeLoopMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? [String: String], let id = selection["id"],
              let value = selection["value"], let mode = VideoLoopMode(rawValue: value) else { return }
        runOperation(for: id) { [controller] in try await controller!.setOptions(for: id, loopMode: mode) }
    }

    @objc private func stopAll() {
        for task in selections.values { task.cancel() }
        selections.removeAll()
        generations.removeAll()
        runOperation(for: "all") { [controller] in try await controller!.setStopped(true) }
    }

    @objc private func toggleAutomaticPause() {
        let enabled = !(UserDefaults.standard.object(forKey: "pauseWhenCovered") as? Bool ?? true)
        UserDefaults.standard.set(enabled, forKey: "pauseWhenCovered")
        controller.setAutomaticPause(enabled)
        updateMenu()
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = AppLanguage.text("轻工具") + " " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.0")
        alert.informativeText = "剪贴板支持文字、图片与文件引用，搜索、复制与删除，保留 7 或 30 天。首次点击开启记录后工作。最多 1000 条历史，图片缓存最多 2560 MB，仅保存在本机。\n\n每块屏幕可多选图片和视频，自动识别类型并按间隔顺序轮换；列表和间隔自动保存。每块屏幕独立选择照片或视频，配置自动保存在本机。重启应用和屏幕重新连接后自动恢复，手动停止状态也会保存。\n\n照片由系统管理；同一视频共享播放器，不同视频分别播放。默认使用原画和低内存循环，可切换到低耗、均衡或无缝循环。原文件不会修改。\n\n桌面完全被遮挡时暂停，持续 20 秒后释放解码资源并保留静帧；重新可见时从暂停位置恢复，画面就绪后再替换静帧。低内存循环接缝可能短暂停顿。\n\n配置位置：\(DisplayConfigurationStore.applicationStore.url.path)\n\n不联网、不上传文件；可在通用设置中开启登录时启动。"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLanguage.english ? "Could Not Apply or Save Wallpaper" : "无法应用或保存背景"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if controller == nil { pendingOpenURLs.append(url) }
        else { openFile(url) }
    }

    private func openFile(_ url: URL) {
        guard ToolFeature.wallpaper.isEnabled() else { return }
        let displays = DisplayTarget.connected()
        guard !displays.isEmpty else { return }
        var index = 0
        if displays.count > 1 {
            let alert = NSAlert()
            alert.messageText = "应用到哪块屏幕？"
            alert.informativeText = url.lastPathComponent
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            picker.addItems(withTitles: displays.enumerated().map { "屏幕 \($0.offset + 1) · \($0.element.name)" })
            alert.accessoryView = picker
            alert.addButton(withTitle: "应用并保存")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            index = picker.indexOfSelectedItem
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        select(url, kind: type?.conforms(to: .movie) == true ? .video : .photo, id: displays[index].id)
    }

    @objc private func showClipboard() {
        guard ToolFeature.clipboard.isEnabled() else { return }
        if clipboardWindow?.window?.isVisible == true { clipboardWindow?.close(); return }
        if clipboardWindow == nil {
            let panel = ClipboardWindow(store: clipboard)
            panel.onSettings = { [weak self] in self?.clipboardWindow?.close(); self?.showClipboardSettings() }
            panel.onClose = { [weak self, weak panel] in
                DispatchQueue.main.async {
                    guard let self, self.clipboardWindow === panel, panel?.window?.isVisible != true else { return }
                    self.clipboardWindow = nil
                }
            }
            clipboardWindow = panel
        }
        clipboardWindow?.present()
    }

    @objc private func showWallpaperSettings() {
        guard ToolFeature.wallpaper.isEnabled() else { return }
        showClipboardSettings()
        clipboardSettings?.selectSection("wallpaper")
    }

    @objc private func showAppSwitcherSettings() { guard ToolFeature.apps.isEnabled() else { return }; showClipboardSettings(); clipboardSettings?.selectSection("apps") }

    @objc private func showWindowSettings() { guard ToolFeature.windows.isEnabled() else { return }; showClipboardSettings(); clipboardSettings?.selectSection("windows") }

    @objc private func startKeepAwake(_ sender: NSMenuItem) {
        do { try keepAwake.start(minutes: sender.tag) } catch { showError(error) }
    }
    @objc private func stopKeepAwake() { keepAwake.stop() }
    @objc private func showKeepAwakeSettings() {
        guard ToolFeature.awake.isEnabled() else { return }
        showClipboardSettings(); clipboardSettings?.selectSection("awake")
    }

    @objc private func showSettings() { showClipboardSettings(); clipboardSettings?.selectSection("general") }

    @objc private func showClipboardSettings() {
        if clipboardSettings == nil {
            let settings = ClipboardSettingsWindow(store: clipboard)
            settings.configureUnified(backgroundMenu: backgroundMenu, appSwitcher: appSwitcher, windowManager: windowManager, keepAwake: keepAwake)
            settings.onLidSleepChange = { [weak self] in self?.lidDisplaySleep.refresh() }
            settings.onFeatureChange = { [weak self] feature, enabled in self?.applyFeature(feature, enabled: enabled) }
            settings.onLanguageChange = { [weak self] in
                guard let self else { return }
                self.clipboardWindow?.close()
                self.clipboardSettings?.close()
                self.clipboardSettings = nil
                self.updateMenu()
                self.showSettings()
            }
            settings.onShortcutChange = { [weak self] value in
                guard let self, ToolFeature.clipboard.isEnabled(), !self.appSwitcher.containsShortcut(value), !self.windowManager.contains(value), self.clipboardShortcut.register(value) else { return false }
                value.save()
                self.shortcutRegistered = true
                self.updateMenu()
                return true
            }
            settings.onClose = { [weak self, weak settings] in
                DispatchQueue.main.async {
                    guard let self, self.clipboardSettings === settings, settings?.window?.isVisible != true else { return }
                    self.clipboardSettings = nil
                }
            }
            clipboardSettings = settings
        }
        clipboardSettings?.selectSection("clipboard")
        clipboardSettings?.present()
    }

    private func applyFeature(_ feature: ToolFeature, enabled: Bool) {
        switch feature {
        case .clipboard:
            clipboardWindow?.close(); clipboardWindow = nil
            clipboard.setSuspended(!enabled || controller.policy.displayAsleep || controller.policy.systemAsleep || controller.policy.sessionInactive)
            if enabled { shortcutRegistered = clipboardShortcut.register() }
            else { clipboardShortcut.unregister(); shortcutRegistered = false }
        case .apps:
            appSwitcher.setFeatureEnabled(enabled)
        case .awake:
            if !enabled { keepAwake.stop() }
        case .windows:
            windowManager.setEnabled(enabled)
        case .wallpaper:
            for task in selections.values { task.cancel() }
            selections.removeAll(); generations.removeAll(); refreshTask?.cancel()
            controller.setFeatureEnabled(enabled)
            if enabled { refreshDisplays() }
        }
        updateMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        for task in selections.values { task.cancel() }
        refreshTask?.cancel()
        windowManager.setEnabled(false)
        lidDisplaySleep.stop()
        keepAwake.stop(notify: false)
        clipboard?.stop()
        clipboardWindow?.close()
        clipboardSettings?.close()
        controller?.shutdown()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}

@main
struct Main {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
