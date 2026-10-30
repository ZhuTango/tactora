import AppKit
import Carbon

@MainActor
final class OCRManager {
    static let defaultShortcut = ClipboardShortcut(keyCode: 2, modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧D")
    static func savedShortcut(defaults: UserDefaults = .standard) -> ClipboardShortcut? {
        if defaults.bool(forKey: "ocrShortcutCleared") { return nil }
        guard let data = defaults.data(forKey: "ocrShortcut"), let value = try? JSONDecoder().decode(ClipboardShortcut.self, from: data), value.isValid else { return defaultShortcut }
        return value
    }
    static func savedContains(_ value: ClipboardShortcut, defaults: UserDefaults = .standard) -> Bool {
        guard let saved = savedShortcut(defaults: defaults) else { return false }
        return saved.keyCode == value.keyCode && saved.modifiers == value.modifiers
    }
    private let store: ClipboardStore
    private let defaults: UserDefaults
    private let hotkey = GlobalClipboardShortcut()
    private var process: Process?
    private var task: Task<Void, Never>?
    private var toast: NSPanel?
    private var toastTask: Task<Void, Never>?
    private(set) var busy = false
    private(set) var status = ""
    var conflicts: ((ClipboardShortcut) -> Bool)?
    var onChange: (() -> Void)?
    var onCapture: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var keepLineBreaks: Bool {
        get { defaults.object(forKey: "ocrKeepLineBreaks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ocrKeepLineBreaks") }
    }
    var showHistory: Bool {
        get { defaults.bool(forKey: "ocrShowHistory") }
        set { defaults.set(newValue, forKey: "ocrShowHistory") }
    }
    var shortcut: ClipboardShortcut? { Self.savedShortcut(defaults: defaults) }
    init(store: ClipboardStore, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        hotkey.action = { [weak self] in self?.capture() }
    }
    @discardableResult func setShortcut(_ value: ClipboardShortcut?) -> Bool {
        if let value {
            guard value.isValid, conflicts?(value) != true else { notify("快捷键已被其他功能使用", "Shortcut is already used"); return false }
            guard !ToolFeature.ocr.isEnabled(in: defaults) || hotkey.register(value) else { notify("快捷键无法注册，请换一个组合", "Shortcut unavailable"); return false }
            defaults.set(try? JSONEncoder().encode(value), forKey: "ocrShortcut")
        } else { hotkey.unregister(); defaults.removeObject(forKey: "ocrShortcut") }
        defaults.set(value == nil, forKey: "ocrShortcutCleared")
        status = ""; onChange?(); return true
    }
    func refreshEnabled() {
        if ToolFeature.ocr.isEnabled(in: defaults) {
            if let value = shortcut, conflicts?(value) == true || !hotkey.register(value) {
                status = AppLanguage.english ? "Shortcut unavailable; choose another in OCR settings." : "截图识字快捷键被占用，请在设置中重新配置。"
            }
        } else {
            status = ""
            hotkey.unregister(); task?.cancel()
            if process?.isRunning == true { process?.terminate() }
            toast?.orderOut(nil)
        }
        onChange?()
    }
    func stop() {
        hotkey.unregister(); task?.cancel(); toastTask?.cancel(); toast?.orderOut(nil)
        if process?.isRunning == true { process?.terminate() }
    }
    func capture() {
        guard ToolFeature.ocr.isEnabled(in: defaults), !busy else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = AppLanguage.english ? "Screen Recording permission required" : "截图识字需要屏幕录制权限"
            alert.informativeText = AppLanguage.english ? "Allow Tactora in System Settings → Privacy & Security → Screen Recording, then try again. Recognition stays on this Mac." : "请在系统设置 → 隐私与安全 → 屏幕录制中允许方寸，再重试。识别仅在本机进行。"
            alert.addButton(withTitle: AppLanguage.english ? "Open Settings" : "打开设置")
            alert.addButton(withTitle: AppLanguage.english ? "Cancel" : "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        onCapture?()
        toast?.orderOut(nil)
        busy = true; onChange?()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tactora-ocr-" + UUID().uuidString)
        let url = directory.appendingPathComponent("capture.png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-i", "-s", "-x", "-t", "png", url.path]
            capture.standardOutput = FileHandle.nullDevice; capture.standardError = FileHandle.nullDevice
            capture.terminationHandler = { [weak self] result in
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: directory) }
                    guard let self else { return }
                    self.process = nil; self.busy = false
                    guard ToolFeature.ocr.isEnabled(in: self.defaults), result.terminationStatus == 0,
                          let data = try? Data(contentsOf: url) else { self.onChange?(); return }
                    self.recognize(data)
                }
            }
            process = capture
            try capture.run()
        } catch {
            process = nil; busy = false; try? FileManager.default.removeItem(at: directory)
            notify("无法启动截图：" + error.localizedDescription, "Could not capture: " + error.localizedDescription)
        }
    }
    func recognizeImage(at url: URL) {
        guard ToolFeature.ocr.isEnabled(in: defaults), !busy else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 40 * 1024 * 1024 else { throw NSError(domain: "TactoraOCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片超过 40 MB"] ) }
            recognize(try Data(contentsOf: url))
        } catch { notify("无法读取图片：" + error.localizedDescription, "Could not read image: " + error.localizedDescription) }
    }
    private func recognize(_ data: Data) {
        guard !busy, ToolFeature.ocr.isEnabled(in: defaults) else { return }
        busy = true; status = AppLanguage.english ? "Recognizing…" : "正在识别…"; onChange?()
        let keep = keepLineBreaks
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try OCRRecognition.recognize(data, keepLineBreaks: keep) } }.value
            guard let self else { return }
            defer { self.busy = false; self.task = nil; self.onChange?() }
            guard !Task.isCancelled, ToolFeature.ocr.isEnabled(in: self.defaults) else { return }
            switch result {
            case .success(let text):
                guard !text.isEmpty else { self.notify("未识别到文字，原剪贴板已保留", "No text found; clipboard unchanged"); return }
                do {
                    let recorded = try self.store.copyOCRText(text)
                    self.notify("已复制 · \(text.count) 字", "Copied · \(text.count) characters", success: true)
                    if self.showHistory && recorded { self.onShowHistory?() }
                } catch { self.notify(error.localizedDescription, error.localizedDescription) }
            case .failure(let error): self.notify("识别失败：" + error.localizedDescription, "Recognition failed: " + error.localizedDescription)
            }
        }
    }
    private func notify(_ chinese: String, _ english: String, success: Bool = false) {
        status = AppLanguage.english ? english : chinese; onChange?()
        toastTask?.cancel(); toast?.orderOut(nil)
        let view = OCRToastView(message: status, success: success)
        let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.ignoresMouseEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = view
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - view.bounds.width / 2, y: screen.visibleFrame.minY + 48)) }
        panel.orderFrontRegardless(); toast = panel
        toastTask = Task { [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: success ? 2_000_000_000 : 4_000_000_000)
            guard !Task.isCancelled, let panel else { return }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    panel.animator().alphaValue = 0
                }
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil); self?.toast = nil
        }
    }

}

/// Compact, non-interactive feedback; size follows the message instead of a fixed empty box.
@MainActor
final class OCRToastView: NSVisualEffectView {
    init(message: String, success: Bool) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = min(320, ceil((message as NSString).size(withAttributes: [.font: font]).width) + 2)
        let textHeight = max(18, ceil((message as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height))
        let width = max(166, textWidth + 62), height = max(44, textHeight + 24)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        material = .hudWindow; state = .active; blendingMode = .behindWindow
        wantsLayer = true; layer?.cornerRadius = 14; layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 15, y: (height - 18) / 2, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "info.circle", accessibilityDescription: nil)
        icon.contentTintColor = success ? .systemGreen : .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = font; label.textColor = .labelColor
        label.frame = NSRect(x: 42, y: (height - textHeight) / 2, width: width - 58, height: textHeight)
        addSubview(icon); addSubview(label)
        setAccessibilityLabel(message)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
}

@MainActor
final class OCRSettingsView: NSView {
    private let manager: OCRManager
    private let recorder = SwitcherShortcutRecorder(frame: .zero)
    private let lines = NSButton(checkboxWithTitle: AppLanguage.english ? "Preserve line breaks" : "保留识别文字的换行", target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: AppLanguage.english ? "Show clipboard history after recognition" : "识别后打开剪贴板列表", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    init(manager: OCRManager) {
        self.manager = manager; super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "Screenshot OCR" : "截图识字")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Select an area to recognize Chinese and English locally. Results are copied; history is saved only when clipboard recording is enabled. Esc cancels without changing your clipboard." : "框选屏幕，本地识别中英文并复制。仅在剪贴板记录开启时保存历史；按 Esc 取消，不改变原剪贴板。")
        note.textColor = .secondaryLabelColor
        recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true; recorder.heightAnchor.constraint(equalToConstant: 30).isActive = true
        recorder.setAccessibilityLabel(AppLanguage.english ? "OCR shortcut" : "截图识字快捷键")
        recorder.onRecord = { [weak self] value in guard let self else { return }; _ = self.manager.setShortcut(value); self.refresh() }
        let reset = NSButton(title: AppLanguage.english ? "Reset" : "恢复默认", target: self, action: #selector(resetShortcut))
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Shortcut" : "呼出快捷键"), recorder, reset]); row.spacing = 16
        lines.target = self; lines.action = #selector(optionsChanged)
        history.target = self; history.action = #selector(optionsChanged)
        let start = NSButton(title: AppLanguage.english ? "Capture Text…" : "开始截图识字…", target: self, action: #selector(capture))
        let stack = NSStackView(views: [title, note, row, lines, history, start, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), note.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        manager.onChange = { [weak self] in self?.refresh() }; refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func refresh() {
        if !recorder.isRecording { recorder.title = manager.shortcut?.label ?? (AppLanguage.english ? "Click to record" : "点击录入快捷键") }
        lines.state = manager.keepLineBreaks ? .on : .off; history.state = manager.showHistory ? .on : .off
        status.stringValue = manager.status
    }
    @objc private func resetShortcut() { _ = manager.setShortcut(OCRManager.defaultShortcut); refresh() }
    @objc private func optionsChanged() { manager.keepLineBreaks = lines.state == .on; manager.showHistory = history.state == .on }
    @objc private func capture() { manager.capture() }
}
