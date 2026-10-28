import AppKit
import Carbon

extension WindowLayout {
    @MainActor var title: String {
        let names: [WindowLayout: (String, String)] = [
            .maximize: ("最大化", "Maximize"), .left: ("左半屏", "Left Half"), .right: ("右半屏", "Right Half"),
            .top: ("上半屏", "Top Half"), .bottom: ("下半屏", "Bottom Half"),
            .topLeft: ("左上角", "Top Left"), .topRight: ("右上角", "Top Right"),
            .bottomLeft: ("左下角", "Bottom Left"), .bottomRight: ("右下角", "Bottom Right"),
            .center: ("居中", "Center"), .restore: ("恢复原尺寸", "Restore"), .fullscreen: ("系统全屏切换", "Toggle Full Screen")]
        return AppLanguage.english ? names[self]!.1 : names[self]!.0
    }
    var defaultShortcut: ClipboardShortcut? {
        let keys: [WindowLayout: (Int, String)] = [.maximize: (kVK_ANSI_M, "M"), .left: (kVK_LeftArrow, "←"),
            .right: (kVK_RightArrow, "→"), .top: (kVK_UpArrow, "↑"), .bottom: (kVK_DownArrow, "↓")]
        guard let key = keys[self] else { return nil }
        return ClipboardShortcut(keyCode: UInt32(key.0), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘" + key.1)
    }
}

@MainActor
final class WindowManager {
    private let defaults: UserDefaults
    private var hotkeys: [WindowLayout: GlobalClipboardShortcut] = [:]
    private var bindings: [String: ClipboardShortcut] = [:]
    private var originals: [(AXUIElement, CGRect)] = []
    private(set) var enabled = false
    private(set) var status = ""
    private(set) var loadError = false
    var onChange: (() -> Void)?
    var conflicts: ((ClipboardShortcut) -> Bool)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "windowLayoutShortcuts") {
            if let saved = try? JSONDecoder().decode([String: ClipboardShortcut].self, from: data), saved.values.allSatisfy(\.isValid) { bindings = saved }
            else { loadError = true; status = "窗口快捷键配置无法读取，原配置已保留。" }
        } else {
            for action in WindowLayout.allCases { bindings[action.rawValue] = action.defaultShortcut }
        }
    }
    func shortcut(_ action: WindowLayout) -> ClipboardShortcut? { bindings[action.rawValue] }
    func contains(_ value: ClipboardShortcut) -> Bool {
        bindings.values.contains { $0.keyCode == value.keyCode && $0.modifiers == value.modifiers }
    }
    static func savedContains(_ value: ClipboardShortcut, defaults: UserDefaults = .standard) -> Bool {
        WindowManager(defaults: defaults).contains(value)
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        hotkeys.removeAll()
        guard value, !loadError else { return }
        status = ""
        for action in WindowLayout.allCases {
            guard let value = shortcut(action) else { continue }
            if conflicts?(value) == true || !install(action, value) { status += "\(action.title)：快捷键被占用。 " }
        }
        onChange?()
    }
    private func install(_ action: WindowLayout, _ value: ClipboardShortcut) -> Bool {
        let key = hotkeys[action] ?? GlobalClipboardShortcut()
        key.action = { [weak self] in self?.perform(action) }
        guard key.register(value) else { return false }
        hotkeys[action] = key
        return true
    }
    func configure(_ action: WindowLayout, shortcut value: ClipboardShortcut?) throws {
        func failure(_ text: String) -> NSError { NSError(domain: "WindowManager", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard !loadError else { throw failure(status) }
        if let value {
            guard value.isValid else { throw failure("请使用包含 Control、Option 或 Command 的组合键。") }
            guard conflicts?(value) != true, !bindings.contains(where: { $0.key != action.rawValue && $0.value.keyCode == value.keyCode && $0.value.modifiers == value.modifiers }) else { throw failure("快捷键已用于其他动作或功能，原配置已保留。") }
            guard !enabled || install(action, value) else { throw failure("快捷键被系统或其他应用占用，原配置已保留。") }
        } else { hotkeys.removeValue(forKey: action) }
        bindings[action.rawValue] = value
        defaults.set(try JSONEncoder().encode(bindings), forKey: "windowLayoutShortcuts")
        status = ""; onChange?()
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func report(_ message: String) { status = message; NSSound.beep(); onChange?() }
    func perform(_ action: WindowLayout) {
        guard enabled else { return }
        guard AXIsProcessTrusted() else { report("请在系统设置 → 隐私与安全性 → 辅助功能中允许轻工具控制窗口。"); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let raw = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { report("当前应用没有可调整的窗口。"); return }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        if action == .fullscreen {
            let fullscreen = attribute(window, "AXFullScreen") as? Bool ?? false
            guard AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!fullscreen) as CFBoolean) == .success else { report("此窗口不支持系统全屏。"); return }
            status = ""; onChange?(); return
        }
        guard attribute(window, "AXFullScreen") as? Bool != true else { report("请先退出系统全屏，再调整窗口布局。"); return }
        guard let current = rect(window), current.width > 0, current.height > 0 else { report("无法读取当前窗口尺寸。"); return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let areas = NSScreen.screens.map { screen -> CGRect in
            let f = screen.visibleFrame
            return CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
        }
        guard let area = areas.max(by: { a, b in
            let x = a.intersection(current); let y = b.intersection(current)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }) else { return }
        var target = action.frame(in: area, current: current)
        let saved = originals.firstIndex { CFEqual($0.0, window) }
        if action == .restore {
            guard let saved else { report("这个窗口还没有可恢复的尺寸。"); return }
            target = originals[saved].1
            if !areas.contains(where: { $0.intersects(target) }) { target = WindowLayout.center.frame(in: area, current: target) }
        } else if saved == nil {
            if originals.count >= 32 { originals.removeFirst() }
            originals.append((window, current))
        }
        var position = target.origin; var size = target.size
        let p = AXValueCreate(.cgPoint, &position)!; let s = AXValueCreate(.cgSize, &size)!
        // Some applications clamp position against the current size; resize before and after moving.
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        guard moved == .success, resized == .success else { report("此窗口不允许移动或调整大小。"); return }
        if action == .restore, let saved { originals.remove(at: saved) }
        if let actual = rect(window), abs(actual.width - target.width) > 3 || abs(actual.height - target.height) > 3 {
            status = "已调整；应用自身的最小窗口尺寸限制了分屏大小。"
        } else { status = "" }
        onChange?()
    }
}

@MainActor
final class WindowManagerSettingsView: NSView {
    private let manager: WindowManager
    private let status = NSTextField(wrappingLabelWithString: "")
    private var recorders: [WindowLayout: SwitcherShortcutRecorder] = [:]
    init(manager: WindowManager) {
        self.manager = manager
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: AppLanguage.english ? "Window Management" : "窗口管理")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Resize the focused window. Click to record · Esc cancels · Backspace clears. Maximize keeps the menu bar and Dock."
            : "调整当前窗口。点击录入快捷键 · Esc 取消 · Backspace 清除。最大化保留菜单栏和 Dock。")
        note.textColor = .secondaryLabelColor
        let permission = SettingsFeedbackButton(title: AppLanguage.english ? "Accessibility Settings…" : "辅助功能授权…", target: self, action: #selector(openPermission))
        status.textColor = .secondaryLabelColor
        let rows = NSStackView(); rows.orientation = .vertical; rows.spacing = 6
        for action in WindowLayout.allCases {
            let label = NSTextField(labelWithString: action.title)
            let recorder = SwitcherShortcutRecorder(frame: .zero)
            recorder.setAccessibilityLabel(action.title + " 快捷键")
            recorder.toolTip = "Esc 取消 · Backspace 清除"
            recorder.onRecord = { [weak self] value in
                guard let self else { return }
                do { try manager.configure(action, shortcut: value) }
                catch { self.status.stringValue = error.localizedDescription }
                self.updateTitles()
            }
            recorders[action] = recorder
            recorder.widthAnchor.constraint(equalToConstant: 190).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 30).isActive = true
            let row = NSStackView(views: [label, NSView(), recorder]); row.spacing = 12
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = rows
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12).isActive = true
        rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        let stack = NSStackView(views: [heading, note, permission, status, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        manager.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func updateTitles() {
        for (action, recorder) in recorders { recorder.title = manager.shortcut(action)?.label ?? (AppLanguage.english ? "Click to record" : "点击录入快捷键") }
    }
    func refresh() {
        updateTitles()
        status.stringValue = manager.status.isEmpty ? (AXIsProcessTrusted() ? "辅助功能已授权" : "需要辅助功能授权，授权后即可使用快捷键。") : manager.status
    }
    @objc private func openPermission() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
