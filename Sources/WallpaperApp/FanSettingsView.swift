import AppKit

@MainActor final class FanSettingsView: NSView {
    private let manager: FanControlManager
    private let toggle = NSSwitch()
    private let showMenu = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let showBar = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let temperature = NSTextField(labelWithString: "— °C")
    private let readings = NSTextField(wrappingLabelWithString: "正在读取…")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let low = NSTextField(string: "50")
    private let high = NSTextField(string: "80")
    var onToggle: ((Bool) -> Void)?
    init(manager: FanControlManager) {
        self.manager = manager
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "Fan Control" : "风扇温控")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Apple Silicon · Highest detected CPU core temperature" : "Apple Silicon · 按已识别的 CPU 核心最高温度调速")
        note.textColor = .secondaryLabelColor
        toggle.target = self; toggle.action = #selector(toggleControl)
        toggle.setAccessibilityLabel(AppLanguage.english ? "Temperature-based fan control" : "按温度控制风扇")
        toggle.identifier = NSUserInterfaceItemIdentifier("fans.enabled")
        let switchRow = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Temperature control" : "启用温度调速"), toggle])
        switchRow.spacing = 16
        showMenu.title = AppLanguage.english ? "Show in Tactora menu" : "在方寸菜单中显示"
        showBar.title = AppLanguage.english ? "Show in menu bar" : "在系统菜单栏显示"
        showMenu.identifier = NSUserInterfaceItemIdentifier("fans.showInMenu")
        showBar.identifier = NSUserInterfaceItemIdentifier("fans.showInMenuBar")
        for checkbox in [showMenu, showBar] { checkbox.target = self; checkbox.action = #selector(changeDisplay) }
        let displayRow = NSStackView(views: [showMenu, showBar]); displayRow.spacing = 20
        temperature.font = .monospacedDigitSystemFont(ofSize: 32, weight: .medium)
        temperature.setAccessibilityLabel("CPU 核心最高温度")
        readings.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        low.widthAnchor.constraint(equalToConstant: 64).isActive = true
        high.widthAnchor.constraint(equalToConstant: 64).isActive = true
        low.setAccessibilityLabel("开始加速温度（摄氏度）"); high.setAccessibilityLabel("最高转速温度（摄氏度）")
        low.identifier = NSUserInterfaceItemIdentifier("fans.low"); high.identifier = NSUserInterfaceItemIdentifier("fans.high")
        low.stringValue = String(Int(manager.curve.low)); high.stringValue = String(Int(manager.curve.high))
        let apply = NSButton(title: AppLanguage.english ? "Apply" : "应用", target: self, action: #selector(applyCurve))
        apply.bezelStyle = .rounded
        let thresholds = NSStackView(views: [NSTextField(labelWithString: "开始加速"), low, NSTextField(labelWithString: "°C     最高转速"), high, NSTextField(labelWithString: "°C"), apply])
        thresholds.spacing = 8
        let explanation = NSTextField(wrappingLabelWithString: "从风扇最小转速逐步升至最大转速；降温后延迟降速，避免频繁变化。范围 40–95°C，两个温度至少相差 10°C。")
        explanation.textColor = .secondaryLabelColor; explanation.font = .systemFont(ofSize: 12)
        let authorize = NSButton(title: "授权辅助服务", target: self, action: #selector(authorizeHelper))
        let settings = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        let retry = NSButton(title: "重新连接", target: self, action: #selector(retryControl))
        for button in [authorize, settings, retry] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [authorize, settings, retry]); buttons.spacing = 10
        status.setAccessibilityLabel("温控状态"); status.identifier = NSUserInterfaceItemIdentifier("fans.status")
        let caution = NSTextField(wrappingLabelWithString: "关闭后恢复系统自动控制。CPU 温度不代表 GPU 等全部热源，系统热压力异常时自动让出控制。请勿同时运行其他风扇控制软件。未验证机型无法启用。")
        caution.font = .systemFont(ofSize: 12); caution.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, note, displayRow, switchRow, temperature, readings, thresholds, explanation, buttons, status, caution])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18)
        ])
        for label in [readings, explanation, status, caution] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        manager.onChange = { [weak self] in self?.refresh() }
        manager.shouldMonitor = { [weak self] in self?.window?.isVisible == true && self?.isHiddenOrHasHiddenAncestor == false }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func refresh() {
        showMenu.state = manager.showInMenu ? .on : .off
        showBar.state = manager.showInMenuBar ? .on : .off
        toggle.state = manager.enabled ? .on : .off
        onToggle?(manager.enabled)
        status.stringValue = (manager.enabled && !manager.active ? "已开启，当前未接管（将持续自动重连，也可点“重新连接”立即重试）：\n" : "") + manager.message
        if let snapshot = manager.snapshot, let hottest = snapshot.maximumTemperature {
            temperature.stringValue = String(format: "%.1f °C", hottest)
            readings.stringValue = "\(snapshot.chip) · \(snapshot.temperatures.count) 个核心温度传感器\n" + snapshot.fans.map {
                "风扇 \($0.id + 1)   \(Int($0.actual)) RPM   ·   范围 \(Int($0.minimum))–\(Int($0.maximum)) RPM"
            }.joined(separator: "\n")
        } else { temperature.stringValue = "— °C"; readings.stringValue = "尚无可用的核心温度和风扇数据" }
    }
    @objc private func changeDisplay() { manager.setDisplay(menu: showMenu.state == .on, menuBar: showBar.state == .on) }
    @objc private func toggleControl() { manager.setEnabled(toggle.state == .on); onToggle?(manager.enabled) }
    @objc private func applyCurve() {
        guard let start = Double(low.stringValue), let end = Double(high.stringValue) else {
            status.stringValue = "请输入有效的摄氏温度。"; return
        }
        _ = manager.saveCurve(FanCurve(low: start, high: end))
    }
    @objc private func authorizeHelper() { manager.authorize() }
    @objc private func openSettings() { manager.openSystemSettings() }
    @objc private func retryControl() { manager.setEnabled(true); manager.poll() }
}
