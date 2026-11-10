import AppKit
import Carbon
import UniformTypeIdentifiers

@MainActor
final class ScreenshotManager {
    enum Mode: Int, CaseIterable {
        case area, window, screen
        @MainActor var title: String {
            switch self {
            case .area: return AppLanguage.english ? "Capture Area" : "区域截图"
            case .window: return AppLanguage.english ? "Capture Window" : "窗口截图"
            case .screen: return AppLanguage.english ? "Capture Screen" : "全屏截图"
            }
        }
    }
    static let defaultShortcut = ClipboardShortcut(keyCode: 1, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧S")
    private let defaults: UserDefaults
    private let hotkey = GlobalClipboardShortcut()
    private var process: Process?
    private var pendingCapture: Task<Void, Never>?
    private var generation = UUID()
    private var previews: [UUID: ScreenshotWindow] = [:]
    private var pins: [NSWindow] = []
    private(set) var busy = false
    private(set) var status = ""
    var onChange: (() -> Void)?
    var onCapture: (() -> Void)?
    var canCapture: (() -> Bool)?
    var conflicts: ((ClipboardShortcut) -> Bool)?
    var onOCR: ((Data) -> Void)?
    var shortcut: ClipboardShortcut? {
        if defaults.bool(forKey: "screenshot.shortcutCleared") { return nil }
        guard let data = defaults.data(forKey: "screenshot.shortcut"),
              let value = try? JSONDecoder().decode(ClipboardShortcut.self, from: data), value.isValid else { return Self.defaultShortcut }
        return value
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey.action = { [weak self] in self?.capture(.area) }
    }
    func contains(_ value: ClipboardShortcut) -> Bool {
        shortcut.map { $0.keyCode == value.keyCode && $0.modifiers == value.modifiers } ?? false
    }
    @discardableResult func setShortcut(_ value: ClipboardShortcut?) -> Bool {
        if let value {
            guard value.isValid, conflicts?(value) != true,
                  !ToolFeature.screenshot.isEnabled(in: defaults) || hotkey.register(value) else {
                status = AppLanguage.english ? "Shortcut unavailable" : "快捷键已被占用"
                onChange?(); return false
            }
            defaults.set(try? JSONEncoder().encode(value), forKey: "screenshot.shortcut")
        } else {
            hotkey.unregister()
            defaults.removeObject(forKey: "screenshot.shortcut")
        }
        defaults.set(value == nil, forKey: "screenshot.shortcutCleared")
        status = ""; onChange?(); return true
    }
    func refreshEnabled() {
        if !ToolFeature.screenshot.isEnabled(in: defaults) { stop(); return }
        if let value = shortcut, conflicts?(value) == true || !hotkey.register(value) {
            status = AppLanguage.english ? "Shortcut unavailable; change it in Settings." : "快捷键被占用，请在截图设置中修改。"
        } else { status = "" }
        onChange?()
    }
    func stop() {
        generation = UUID()
        pendingCapture?.cancel(); pendingCapture = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; busy = false
        hotkey.unregister()
        let windows = Array(previews.values)
        windows.forEach { $0.close() }
        previews.removeAll()
        pins.forEach { $0.close() }; pins.removeAll()
        onChange?()
    }
    func capture(_ mode: Mode) {
        guard ToolFeature.screenshot.isEnabled(in: defaults), !busy else { return }
        guard canCapture?() != false else {
            status = AppLanguage.english ? "Another capture is in progress" : "其他截图正在进行，请完成后重试"
            onChange?(); return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = AppLanguage.english ? "Screen Recording permission required" : "截图需要屏幕录制权限"
            alert.informativeText = AppLanguage.english ? "Allow Tactora in System Settings → Privacy & Security → Screen Recording." : "请在系统设置 → 隐私与安全 → 屏幕录制中允许方寸。"
            alert.addButton(withTitle: AppLanguage.english ? "Open Settings" : "打开设置")
            alert.addButton(withTitle: AppLanguage.english ? "Cancel" : "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        busy = true; status = ""; generation = UUID()
        let token = generation
        onCapture?()
        previews.values.forEach { $0.window?.orderOut(nil) }
        pins.removeAll { !$0.isVisible }
        pins.forEach { $0.orderOut(nil) }
        // Allow the triggering menu and our own windows to leave the compositor.
        pendingCapture = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.runCapture(mode, token: token)
        }
        onChange?()
    }
    private func runCapture(_ mode: Mode, token: UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tactora-screenshot-" + UUID().uuidString)
        let url = directory.appendingPathComponent("capture.png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            var arguments = ["-x", "-t", "png"]
            switch mode {
            case .area: arguments += ["-i", "-s"]
            case .window: arguments += ["-i", "-w", "-o"]
            case .screen:
                let index = NSScreen.screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) } ?? 0
                arguments += ["-D", String(index + 1)]
            }
            capture.arguments = arguments + [url.path]
            capture.standardOutput = FileHandle.nullDevice
            capture.standardError = FileHandle.nullDevice
            capture.terminationHandler = { [weak self] result in
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: directory) }
                    guard let self, token == self.generation else { return }
                    self.process = nil; self.pendingCapture = nil; self.busy = false
                    self.restoreWindows()
                    if result.terminationStatus == 0, let image = NSImage(contentsOf: url) {
                        self.present(image)
                    } else if mode == .screen {
                        self.status = AppLanguage.english ? "Capture failed. Check Screen Recording permission." : "截图失败，请检查屏幕录制权限。"
                    }
                    self.onChange?()
                }
            }
            process = capture
            try capture.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            process = nil; busy = false; restoreWindows()
            status = error.localizedDescription; onChange?()
        }
    }
    private func restoreWindows() {
        previews.values.forEach { $0.window?.orderFront(nil) }
        pins.forEach { $0.orderFront(nil) }
    }
    func present(_ image: NSImage) {
        let id = UUID()
        let preview = ScreenshotWindow(image: image)
        preview.onClose = { [weak self] in self?.previews.removeValue(forKey: id) }
        preview.onPin = { [weak self] image in self?.pin(image) }
        preview.onOCR = { [weak self] data in self?.onOCR?(data) }
        previews[id] = preview
        preview.showWindow(nil)
        preview.window?.makeKeyAndOrderFront(nil)
    }
    private func pin(_ image: NSImage) {
        pins.removeAll { !$0.isVisible }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let scale = min(1, min(500 / image.size.width, 400 / image.size.height))
        let panel = NSPanel(contentRect: NSRect(x: screen.midX - 200, y: screen.midY - 150, width: max(120, image.size.width * scale), height: max(80, image.size.height * scale)), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = AppLanguage.english ? "Pinned Screenshot" : "贴图"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSImageView()
        view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(panel.title)
        panel.contentView = view
        pins.append(panel); panel.orderFront(nil)
    }
}

@MainActor
final class ScreenshotSettingsView: NSView {
    private let manager: ScreenshotManager
    private let recorder = SwitcherShortcutRecorder(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    init(manager: ScreenshotManager) {
        self.manager = manager
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: AppLanguage.english ? "Screenshot" : "截图")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Capture, copy, save, annotate or pin. Escape cancels selection. Full screen captures the display under the pointer." : "截图后可复制、保存、标注或贴图。Esc 取消选区，全屏截图使用鼠标所在屏幕。")
        hint.textColor = .secondaryLabelColor
        recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 32).isActive = true
        recorder.setAccessibilityLabel(AppLanguage.english ? "Capture area shortcut" : "区域截图快捷键")
        recorder.onRecord = { [weak self] value in _ = self?.manager.setShortcut(value); self?.refresh() }
        let reset = NSButton(title: AppLanguage.english ? "Reset" : "恢复默认", target: self, action: #selector(resetShortcut))
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Shortcut" : "快捷键"), recorder, reset])
        row.spacing = 12
        let buttons = NSStackView()
        buttons.spacing = 12
        for mode in ScreenshotManager.Mode.allCases {
            let button = NSButton(title: mode.title, target: self, action: #selector(capture(_:)))
            button.tag = mode.rawValue; buttons.addArrangedSubview(button)
        }
        let stack = NSStackView(views: [heading, hint, row, buttons, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        manager.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func refresh() {
        if !recorder.isRecording { recorder.title = manager.shortcut?.label ?? (AppLanguage.english ? "Click to record" : "点击录入") }
        status.stringValue = manager.busy ? (AppLanguage.english ? "Capturing…" : "正在截图…") : manager.status
    }
    @objc private func resetShortcut() { _ = manager.setShortcut(ScreenshotManager.defaultShortcut); refresh() }
    @objc private func capture(_ sender: NSButton) {
        if let mode = ScreenshotManager.Mode(rawValue: sender.tag) { manager.capture(mode) }
    }
}
