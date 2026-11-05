import AppKit
import Carbon

@MainActor
final class QuickActionsShortcut {
    static let defaultShortcut = ClipboardShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")
    private let defaults: UserDefaults
    private let hotkey = GlobalClipboardShortcut()
    var conflicts: ((ClipboardShortcut) -> Bool)?
    var onOpen: (() -> Void)?
    var onChange: (() -> Void)?
    private(set) var status = ""
    var shortcut: ClipboardShortcut? {
        if defaults.bool(forKey: "quickActions.shortcutCleared") { return nil }
        guard let data = defaults.data(forKey: "quickActions.shortcut"),
              let value = try? JSONDecoder().decode(ClipboardShortcut.self, from: data), value.isValid else { return Self.defaultShortcut }
        return value
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey.action = { [weak self] in self?.onOpen?() }
    }
    func contains(_ value: ClipboardShortcut) -> Bool {
        shortcut.map { $0.keyCode == value.keyCode && $0.modifiers == value.modifiers } ?? false
    }
    @discardableResult func setShortcut(_ value: ClipboardShortcut?) -> Bool {
        if let value {
            guard value.isValid, conflicts?(value) != true, hotkey.register(value) else {
                status = AppLanguage.english ? "Shortcut unavailable. Previous shortcut kept." : "快捷键已被占用，已保留原快捷键。"
                onChange?()
                return false
            }
            defaults.set(try? JSONEncoder().encode(value), forKey: "quickActions.shortcut")
        } else {
            hotkey.unregister()
            defaults.removeObject(forKey: "quickActions.shortcut")
        }
        defaults.set(value == nil, forKey: "quickActions.shortcutCleared")
        status = ""
        onChange?()
        return true
    }
    func start() {
        guard let value = shortcut else { return }
        if conflicts?(value) == true || !hotkey.register(value) {
            status = AppLanguage.english ? "Shortcut unavailable; use the menu to change it." : "快捷键被占用，可从菜单打开设置修改。"
        }
    }
    func stop() { hotkey.unregister() }
}

@MainActor
final class QuickActionsSettingsView: NSView {
    private let manager: QuickActionsShortcut
    private let recorder = SwitcherShortcutRecorder(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    init(manager: QuickActionsShortcut) {
        self.manager = manager
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: AppLanguage.english ? "Quick Actions" : "快捷操作")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Search actions and apps. Paste JSON or a timestamp to open Text Tools. Use the star to save favorites." : "搜索操作与应用，粘贴 JSON 或时间戳进入文本处理。点击星标收藏常用操作。")
        hint.textColor = .secondaryLabelColor
        recorder.identifier = NSUserInterfaceItemIdentifier("quickActions.shortcut")
        recorder.setAccessibilityLabel(AppLanguage.english ? "Quick Actions shortcut" : "快捷操作呼出快捷键")
        recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 32).isActive = true
        recorder.onRecord = { [weak self] value in
            guard let self else { return }
            _ = self.manager.setShortcut(value)
            self.refresh()
        }
        let reset = NSButton(title: AppLanguage.english ? "Reset" : "恢复默认", target: self, action: #selector(resetShortcut))
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Shortcut" : "呼出快捷键"), recorder, reset])
        row.spacing = 16
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Click to record. Delete clears the shortcut; Esc cancels. The menu entry remains available." : "点击录制，Delete 清除快捷键，Esc 取消。也可从方寸菜单打开。")
        note.textColor = .secondaryLabelColor
        let open = NSButton(title: AppLanguage.english ? "Open Quick Actions" : "打开快捷操作", target: self, action: #selector(openPanel))
        let stack = NSStackView(views: [heading, hint, row, note, open, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func refresh() {
        if !recorder.isRecording { recorder.title = manager.shortcut?.label ?? (AppLanguage.english ? "Click to record" : "点击录入") }
        status.stringValue = manager.status
    }
    @objc private func resetShortcut() { _ = manager.setShortcut(QuickActionsShortcut.defaultShortcut); refresh() }
    @objc private func openPanel() { manager.onOpen?() }
}
