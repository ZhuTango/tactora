import AppKit
import IOKit.hid
import ServiceManagement

@MainActor
final class KeyboardSettingsView: NSView {
    private let controller: KeyboardController
    private let picker = NSPopUpButton()
    private let shield = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let deviceNote = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private let helperButton = SettingsFeedbackButton()
    private let add = SettingsFeedbackButton()
    private let swap = SettingsFeedbackButton()
    private var devices: [KeyboardDevice] = []
    private var selectedID: String?
    private var draft: KeyboardProfile?
    private var lastInventory: [KeyboardDevice] = []
    var onEmergencyStop: (() -> Void)?
    init(controller: KeyboardController) {
        self.controller = controller
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "Keyboard" : "键盘管理")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Device-specific mappings · saved automatically · no external driver"
            : "按键盘独立配置 · 自动保存 · 无需第三方驱动")
        detail.textColor = .secondaryLabelColor
        picker.target = self; picker.action = #selector(selectDevice)
        picker.setAccessibilityIdentifier("keyboard.device")
        picker.setAccessibilityLabel(AppLanguage.english ? "Keyboard device" : "选择键盘")
        let refresh = SettingsFeedbackButton(title: AppLanguage.english ? "Retry" : "重新检测", target: self, action: #selector(retry))
        let restore = SettingsFeedbackButton(title: AppLanguage.english ? "Restore all keyboards" : "恢复所有键盘", target: self, action: #selector(emergency))
        refresh.bezelStyle = .rounded; restore.bezelStyle = .rounded
        restore.toolTip = "停用键盘管理并恢复方寸更改的键位，配置仍保留。"
        let deviceRow = NSStackView(views: [picker, refresh, restore]); deviceRow.spacing = 12
        deviceNote.font = .systemFont(ofSize: 11); deviceNote.textColor = .secondaryLabelColor
        shield.title = AppLanguage.english ? "Disable built-in keyboard while this keyboard is connected" : "此键盘连接时，屏蔽内置键盘"
        shield.target = self; shield.action = #selector(toggleShield)
        shield.setAccessibilityIdentifier("keyboard.disableBuiltIn")
        let shieldHelp = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Built-in keyboard only; trackpad and Touch ID stay available. Disconnecting the external keyboard restores input automatically. Sleep, lock, disabling or quitting also releases it."
            : "仅屏蔽内置键盘，保留触控板与 Touch ID。外置键盘断开后自动恢复；休眠、锁屏、停用或退出也会释放屏蔽。")
        shieldHelp.font = .systemFont(ofSize: 11); shieldHelp.textColor = .secondaryLabelColor
        let permission = SettingsFeedbackButton(title: AppLanguage.english ? "Input Monitoring…" : "输入监控权限…", target: self, action: #selector(openPermission))
        permission.bezelStyle = .rounded
        helperButton.title = AppLanguage.english ? "Enable protection helper…" : "启用屏蔽辅助服务…"
        helperButton.target = self; helperButton.action = #selector(enableHelper); helperButton.bezelStyle = .rounded
        helperButton.toolTip = "方寸自己的管理员辅助服务，只接收已签名方寸的内置键盘屏蔽请求；不读取或记录按键。"
        helperButton.setAccessibilityIdentifier("keyboard.helper")
        let permissionRow = NSStackView(views: [helperButton, permission]); permissionRow.spacing = 12
        let protection = KeyboardSettingsCard(title: AppLanguage.english ? "Built-in keyboard protection" : "内置键盘保护", views: [shield, shieldHelp, permissionRow])
        add.title = AppLanguage.english ? "Add mapping" : "添加映射"; add.target = self; add.action = #selector(addMapping); add.bezelStyle = .rounded
        swap.title = AppLanguage.english ? "Swap left ⌘ / ⌥" : "交换左 ⌘ / ⌥"; swap.target = self; swap.action = #selector(swapModifiers); swap.bezelStyle = .rounded
        let actions = NSStackView(views: [add, swap]); actions.spacing = 12
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let document = KeyboardRowsDocument(); scroll.documentView = document
        rows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(rows)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            scroll.heightAnchor.constraint(equalToConstant: 110)
        ])
        let mapHelp = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Physical key → replacement key. Fn / Globe, Touch ID and media keys are not supported."
            : "原按键 → 替换按键。首版支持单键映射；Fn / 地球键、Touch ID 和媒体键暂不支持。")
        mapHelp.font = .systemFont(ofSize: 11); mapHelp.textColor = .secondaryLabelColor
        let mapping = KeyboardSettingsCard(title: AppLanguage.english ? "Key mappings" : "键位映射", views: [actions, scroll, mapHelp])
        status.font = .systemFont(ofSize: 12); status.setAccessibilityIdentifier("keyboard.status")
        let stack = NSStackView(views: [title, detail, deviceRow, deviceNote, protection, mapping, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            protection.widthAnchor.constraint(equalTo: stack.widthAnchor), mapping.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: mapping.widthAnchor, constant: -32),
            shieldHelp.widthAnchor.constraint(equalTo: protection.widthAnchor, constant: -32),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), deviceNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            picker.widthAnchor.constraint(equalToConstant: 360)
        ])
        controller.onChange = { [weak self] in self?.update() }
        controller.refresh(); update(force: true)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func update(force: Bool = false) {
        switch KeyboardHelperBridge.service.status {
        case .enabled: helperButton.title = AppLanguage.english ? "Protection helper enabled" : "屏蔽辅助服务已启用"
        case .requiresApproval: helperButton.title = AppLanguage.english ? "Approve protection helper…" : "批准屏蔽辅助服务…"
        default: helperButton.title = AppLanguage.english ? "Enable protection helper…" : "启用屏蔽辅助服务…"
        }
        if force || lastInventory != controller.connected {
            lastInventory = controller.connected
            devices = controller.connected + controller.profiles.map(\.device).filter { saved in !controller.connected.contains { $0.id == saved.id } }
            picker.removeAllItems()
            for device in devices {
                let online = controller.connected.contains { $0.id == device.id }
                picker.addItem(withTitle: device.name + (online ? "" : " · 未连接"))
            }
            let index = devices.firstIndex { $0.id == selectedID } ?? 0
            if !devices.isEmpty { picker.selectItem(at: index); selectedID = devices[index].id }
            loadSelection()
        }
        let error = controller.errors[selectedID ?? ""] ?? controller.errors.values.first
        if let error { status.stringValue = error; status.textColor = .systemOrange }
        else {
            status.textColor = .secondaryLabelColor
            if !controller.enabled { status.stringValue = AppLanguage.english ? "Disabled · preferences kept" : "键盘管理已停用，配置已保留。" }
            else if controller.paused { status.stringValue = "当前已暂停，内置键盘已释放。" }
            else if !controller.blocked.isEmpty { status.stringValue = AppLanguage.english ? "Built-in keyboard blocked · settings saved" : "内置键盘已屏蔽 · 设置已保存" }
            else { status.stringValue = AppLanguage.english ? "Settings saved · built-in keyboard available" : "设置已保存 · 内置键盘可用" }
        }
    }
    private func loadSelection() {
        guard let device = devices.first(where: { $0.id == selectedID }) else {
            draft = nil; shield.isEnabled = false; add.isEnabled = false; swap.isEnabled = false
            deviceNote.stringValue = "未检测到物理键盘。"; renderRows(); return
        }
        draft = controller.profile(for: device)
        shield.isEnabled = !device.builtIn; shield.state = draft?.disableBuiltIn == true ? .on : .off
        add.isEnabled = true; swap.isEnabled = true
        deviceNote.stringValue = (device.builtIn ? "内置键盘" : device.transport) + " · " + (controller.connected.contains(where: { $0.id == device.id }) ? "已连接" : "连接后自动应用") + " · 无设备序列号时按连接位置保存"
        renderRows()
    }
    private func renderRows() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, mapping) in (draft?.mappings ?? []).enumerated() {
            let from = keyPicker(mapping.source); from.tag = index * 2
            let to = keyPicker(mapping.destination); to.tag = index * 2 + 1
            let remove = SettingsFeedbackButton(title: "删除", target: self, action: #selector(removeMapping(_:)))
            remove.tag = index; remove.bezelStyle = .rounded; remove.toolTip = "删除此映射并恢复原按键"
            let row = NSStackView(views: [from, NSTextField(labelWithString: "→"), to, remove]); row.spacing = 12
            rows.addArrangedSubview(row)
        }
        if draft?.mappings.isEmpty != false {
            let empty = NSTextField(labelWithString: AppLanguage.english ? "No mappings · original keyboard layout" : "暂无映射，使用原始键位")
            empty.textColor = .secondaryLabelColor; rows.addArrangedSubview(empty)
        }
    }
    private func keyPicker(_ code: UInt64) -> NSPopUpButton {
        let value = NSPopUpButton(); value.addItems(withTitles: KeyboardKey.all.map(\.label))
        value.selectItem(at: KeyboardKey.all.firstIndex { $0.code == code } ?? 0)
        value.target = self; value.action = #selector(changeMapping(_:))
        value.widthAnchor.constraint(equalToConstant: 235).isActive = true
        value.setAccessibilityLabel("按键")
        return value
    }
    private func save() {
        guard let draft else { return }
        do { try controller.save(draft); update() }
        catch { status.stringValue = error.localizedDescription; status.textColor = .systemOrange }
    }
    @objc private func selectDevice() { selectedID = devices.indices.contains(picker.indexOfSelectedItem) ? devices[picker.indexOfSelectedItem].id : nil; loadSelection(); update() }
    @objc private func retry() { controller.refresh(retry: true); update(force: true) }
    @objc private func toggleShield() { draft?.disableBuiltIn = shield.state == .on; save() }
    @objc private func addMapping() {
        guard let first = KeyboardKey.all.first(where: { key in !(draft?.mappings.contains { $0.source == key.code } ?? true) }) else { return }
        draft?.mappings.append(KeyboardMapping(source: first.code, destination: first.code)); save(); renderRows()
    }
    @objc private func removeMapping(_ sender: NSButton) { draft?.mappings.remove(at: sender.tag); save(); renderRows() }
    @objc private func changeMapping(_ sender: NSPopUpButton) {
        guard var value = draft, value.mappings.indices.contains(sender.tag / 2) else { return }
        let index = sender.tag / 2, code = KeyboardKey.all[sender.indexOfSelectedItem].code
        if sender.tag % 2 == 0 && value.mappings.enumerated().contains(where: { $0.offset != index && $0.element.source == code }) {
            status.stringValue = "该原按键已有映射，请编辑对应行。"; status.textColor = .systemOrange; renderRows(); return
        }
        if sender.tag % 2 == 0 { value.mappings[index].source = code } else { value.mappings[index].destination = code }
        draft = value; save()
    }
    @objc private func swapModifiers() {
        let command: UInt64 = 0x7000000e3, option: UInt64 = 0x7000000e2
        draft?.mappings.removeAll { $0.source == command || $0.source == option }
        draft?.mappings += [KeyboardMapping(source: command, destination: option), KeyboardMapping(source: option, destination: command)]
        save(); renderRows()
    }
    @objc private func emergency() {
        controller.emergencyStop(); onEmergencyStop?(); update()
    }
    @objc private func enableHelper() {
        do {
            let service = KeyboardHelperBridge.service
            if service.status == .notRegistered || service.status == .notFound { try service.register(); KeyboardHelperBridge.recordRegistration() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            controller.refresh(retry: true); update()
        } catch {
            if KeyboardHelperBridge.service.status == .requiresApproval {
                status.stringValue = "等待系统批准，请在登录项中允许方寸后台服务。"
                SMAppService.openSystemSettingsLoginItems()
            } else { status.stringValue = "无法启用辅助服务：" + error.localizedDescription }
            status.textColor = .systemOrange
        }
    }
    @objc private func openPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}

@MainActor
private final class KeyboardSettingsCard: NSView {
    init(title: String, views: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1; layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
}

private final class KeyboardRowsDocument: NSView {
    override var isFlipped: Bool { true }
}
