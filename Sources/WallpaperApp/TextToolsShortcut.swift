import AppKit
import Carbon

@MainActor
final class TextToolsShortcut {
    static let defaultShortcut = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘T")
    static func savedShortcut(defaults: UserDefaults = .standard) -> ClipboardShortcut? {
        if defaults.bool(forKey: "textShortcutCleared") { return nil }
        guard let data = defaults.data(forKey: "textShortcut"),
              let value = try? JSONDecoder().decode(ClipboardShortcut.self, from: data), value.isValid else { return defaultShortcut }
        return value
    }
    static func savedContains(_ value: ClipboardShortcut, defaults: UserDefaults = .standard) -> Bool {
        guard let saved = savedShortcut(defaults: defaults) else { return false }
        return saved.keyCode == value.keyCode && saved.modifiers == value.modifiers
    }
    private let defaults: UserDefaults
    private let hotkey = GlobalClipboardShortcut()
    private(set) var status = ""
    var conflicts: ((ClipboardShortcut) -> Bool)?
    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    var shortcut: ClipboardShortcut? { Self.savedShortcut(defaults: defaults) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey.action = { [weak self] in
            guard let self, ToolFeature.text.isEnabled(in: self.defaults) else { return }
            self.onOpen?()
        }
    }
    @discardableResult func setShortcut(_ value: ClipboardShortcut?) -> Bool {
        if let value {
            guard value.isValid, conflicts?(value) != true else {
                status = AppLanguage.english ? "Shortcut already in use. Choose another." : "快捷键已被其他功能使用，请换一个组合。"
                onChange?(); return false
            }
            guard !ToolFeature.text.isEnabled(in: defaults) || hotkey.register(value) else {
                status = AppLanguage.english ? "Shortcut unavailable." : "快捷键无法注册，请换一个组合。"
                onChange?(); return false
            }
            defaults.set(try? JSONEncoder().encode(value), forKey: "textShortcut")
        } else {
            hotkey.unregister()
            defaults.removeObject(forKey: "textShortcut")
        }
        defaults.set(value == nil, forKey: "textShortcutCleared")
        status = ""; onChange?(); return true
    }
    func refreshEnabled() {
        hotkey.unregister(); status = ""
        if ToolFeature.text.isEnabled(in: defaults), let value = shortcut,
           conflicts?(value) == true || !hotkey.register(value) {
            status = AppLanguage.english ? "Shortcut unavailable; choose another in Text Tools settings." : "文本处理快捷键被占用，请在设置中更换。"
        }
        onChange?()
    }
    func stop() { hotkey.unregister() }
}

@MainActor
final class TextToolsSettingsView: NSView {
    private let manager: TextToolsShortcut
    private let recorder = SwitcherShortcutRecorder(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    init(manager: TextToolsShortcut) {
        self.manager = manager
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "Text Tools" : "文本快捷处理")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Open a local workspace for JSON, Unix timestamps and text comparison. Paste manually, or use Process Text in clipboard history." : "快速打开 JSON、时间戳和文本对比面板。手动粘贴内容，或从剪贴板右键选择“处理文本”。")
        note.textColor = .secondaryLabelColor
        recorder.identifier = NSUserInterfaceItemIdentifier("text.shortcut")
        recorder.setAccessibilityLabel(AppLanguage.english ? "Text Tools shortcut" : "文本快捷处理快捷键")
        recorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 32).isActive = true
        recorder.onRecord = { [weak self] value in
            guard let self else { return }
            _ = manager.setShortcut(value); refresh()
        }
        let reset = NSButton(title: AppLanguage.english ? "Reset" : "恢复默认", target: self, action: #selector(resetShortcut))
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Shortcut" : "呼出快捷键"), recorder, reset])
        row.spacing = 16
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Click to record. Press Delete to clear, Esc to cancel. Disabling Text Tools also disables this shortcut." : "点击后直接按组合键；Delete 清除，Esc 取消。关闭文本处理功能后，快捷键同时停用。")
        hint.textColor = .secondaryLabelColor
        let open = NSButton(title: AppLanguage.english ? "Open Text Tools" : "打开文本处理", target: self, action: #selector(openPanel))
        let stack = NSStackView(views: [title, note, row, hint, open, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), note.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func refresh() {
        if !recorder.isRecording { recorder.title = manager.shortcut?.label ?? (AppLanguage.english ? "Click to record" : "点击录入快捷键") }
        status.stringValue = manager.status
    }
    @objc private func resetShortcut() { _ = manager.setShortcut(TextToolsShortcut.defaultShortcut); refresh() }
    @objc private func openPanel() { manager.onOpen?() }
}
