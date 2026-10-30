import AppKit
import Carbon

extension WindowLayout {
    @MainActor var title: String {
        let names: [WindowLayout: (String, String)] = [
            .maximize: ("最大化", "Maximize"), .left: ("左半屏", "Left Half"), .right: ("右半屏", "Right Half"),
            .top: ("上半屏", "Top Half"), .bottom: ("下半屏", "Bottom Half"),
            .topLeft: ("左上角", "Top Left"), .topRight: ("右上角", "Top Right"),
            .bottomLeft: ("左下角", "Bottom Left"), .bottomRight: ("右下角", "Bottom Right"),
            .center: ("居中", "Center"), .restore: ("恢复原尺寸", "Restore"), .fullscreen: ("系统全屏切换", "Toggle Full Screen"),
            .previousDisplay: ("移到上一屏", "Previous Display"), .nextDisplay: ("移到下一屏", "Next Display")]
        return AppLanguage.english ? names[self]!.1 : names[self]!.0
    }
    var defaultShortcut: ClipboardShortcut? {
        let keys: [WindowLayout: (Int, String)] = [.maximize: (kVK_ANSI_M, "M"), .left: (kVK_LeftArrow, "←"),
            .right: (kVK_RightArrow, "→"), .top: (kVK_UpArrow, "↑"), .bottom: (kVK_DownArrow, "↓"),
            .topLeft: (kVK_ANSI_U, "U"), .topRight: (kVK_ANSI_I, "I"),
            .bottomLeft: (kVK_ANSI_J, "J"), .bottomRight: (kVK_ANSI_K, "K"),
            .center: (kVK_ANSI_C, "C"), .restore: (kVK_ANSI_R, "R"), .fullscreen: (kVK_ANSI_F, "F"),
            .previousDisplay: (kVK_ANSI_LeftBracket, "["), .nextDisplay: (kVK_ANSI_RightBracket, "]")]
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
            if let saved = try? JSONDecoder().decode([String: ClipboardShortcut].self, from: data), saved.values.allSatisfy(\.isValid) {
                bindings = saved
                // Migrate only the former default pair; retain cleared/custom/colliding bindings.
                for (action, key): (WindowLayout, Int) in [(.previousDisplay, kVK_ANSI_P), (.nextDisplay, kVK_ANSI_N)] where !defaults.bool(forKey: "windowAdjacentKeysMigrated") {
                    if let old = bindings[action.rawValue], old.keyCode == UInt32(key),
                       old.modifiers == UInt32(controlKey | optionKey | cmdKey),
                       let replacement = action.defaultShortcut, !contains(replacement) {
                        bindings[action.rawValue] = replacement
                    }
                }
                // Only new actions receive defaults during migration; absent old actions stay cleared.
                let known = Set(defaults.stringArray(forKey: "windowLayoutKnownActions") ?? WindowLayout.allCases.filter { $0 != .previousDisplay && $0 != .nextDisplay }.map(\.rawValue))
                for action in WindowLayout.allCases where !known.contains(action.rawValue) && bindings[action.rawValue] == nil {
                    if let value = action.defaultShortcut, !contains(value) { bindings[action.rawValue] = value }
                }
            }
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
        defaults.set(WindowLayout.allCases.map(\.rawValue), forKey: "windowLayoutKnownActions")
        defaults.set(true, forKey: "windowAdjacentKeysMigrated")
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
        guard AXIsProcessTrusted() else {
            // Permission is live state, not a sticky action error.
            status = ""; NSSound.beep(); onChange?(); return
        }
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
        if action == .previousDisplay || action == .nextDisplay {
            guard areas.count > 1 else { report("当前只有一块显示器，无法迁移窗口。"); return }
            let ordered = areas.sorted { $0.minX == $1.minX ? $0.minY < $1.minY : $0.minX < $1.minX }
            guard let index = ordered.firstIndex(of: area) else { return }
            let offset = action == .nextDisplay ? 1 : ordered.count - 1
            target = WindowLayout.transferred(current, from: area, to: ordered[(index + offset) % ordered.count])
        }
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
            let diagram = WindowLayoutDiagram(action: action)
            diagram.widthAnchor.constraint(equalToConstant: 64).isActive = true
            diagram.heightAnchor.constraint(equalToConstant: 34).isActive = true
            let reset = SettingsFeedbackButton(title: "↺", target: self, action: #selector(resetShortcut(_:)))
            reset.cell?.representedObject = action.rawValue
            reset.toolTip = (AppLanguage.english ? "Restore default: " : "恢复默认：") + (action.defaultShortcut?.label ?? "")
            reset.setAccessibilityLabel(action.title + (AppLanguage.english ? " Restore default" : "恢复默认快捷键"))
            reset.widthAnchor.constraint(equalToConstant: 32).isActive = true
            let row = NSStackView(views: [diagram, label, NSView(), recorder, reset]); row.spacing = 12
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
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
    @objc private func resetShortcut(_ sender: NSButton) {
        guard let raw = sender.cell?.representedObject as? String, let action = WindowLayout(rawValue: raw) else { return }
        do { try manager.configure(action, shortcut: action.defaultShortcut); refresh() }
        catch { status.stringValue = error.localizedDescription }
    }
    private func updateTitles() {
        for (action, recorder) in recorders { recorder.title = manager.shortcut(action)?.label ?? (AppLanguage.english ? "Click to record" : "点击录入快捷键") }
    }
    func refresh() {
        updateTitles()
        status.stringValue = Self.permissionMessage(trusted: AXIsProcessTrusted(), actionStatus: manager.status)
    }
    static func permissionMessage(trusted: Bool, actionStatus: String) -> String {
        guard trusted else {
            return AppLanguage.english
                ? "Accessibility permission is missing for this version. If already enabled, remove and re-add the installed Tactora app."
                : "当前版本未获辅助功能授权。若系统中已开启，请移除旧条目，重新添加 /Users/tango/Applications/方寸.app。"
        }
        return actionStatus.isEmpty ? (AppLanguage.english ? "Accessibility permission granted" : "辅助功能已授权") : actionStatus
    }
    @objc private func openPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}


@MainActor
final class WindowLayoutDiagram: NSView {
    let action: WindowLayout
    init(action: WindowLayout) {
        self.action = action
        super.init(frame: .zero)
        toolTip = action.title
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let screen = bounds.insetBy(dx: 3, dy: 4)
        NSColor.secondaryLabelColor.setStroke()
        if action == .previousDisplay || action == .nextDisplay {
            let left = NSRect(x: 2, y: 5, width: 24, height: 23)
            let right = NSRect(x: 38, y: 5, width: 24, height: 23)
            NSBezierPath(roundedRect: left, xRadius: 3, yRadius: 3).stroke()
            NSBezierPath(roundedRect: right, xRadius: 3, yRadius: 3).stroke()
            NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: (action == .nextDisplay ? right : left).insetBy(dx: 3, dy: 3), xRadius: 2, yRadius: 2).fill()
            let symbol = action == .nextDisplay ? "→" : "←"
            (symbol as NSString).draw(at: NSPoint(x: 26, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            return
        }
        let border = NSBezierPath(roundedRect: screen, xRadius: 3, yRadius: 3)
        border.lineWidth = 1; border.stroke()
        let inset = screen.insetBy(dx: 3, dy: 3)
        let normal = NSRect(x: inset.midX - 12, y: inset.midY - 7, width: 24, height: 14)
        let fill = action == .restore ? normal.offsetBy(dx: -5, dy: -2) : action.frame(in: inset, current: normal)
        NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: fill.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
        if action == .fullscreen {
            ("⛶" as NSString).draw(at: NSPoint(x: screen.midX - 6, y: screen.midY - 8), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
        }
    }
}
