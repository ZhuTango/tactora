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
    private var trendWindow: NSPanel?
    private let warnings = NSButton(checkboxWithTitle: AppLanguage.english ? "Persistent issue alerts" : "持续异常提醒", target: nil, action: nil)
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
        let trend = NSButton(title: AppLanguage.english ? "15-minute trend" : "近 15 分钟曲线", target: self, action: #selector(showTrend))
        warnings.target = self; warnings.action = #selector(changeWarnings)
        warnings.toolTip = "开启后监测持续高温；已接管风扇时也监测读数缺失。连续 30 秒后提醒。"
        let trendRow = NSStackView(views: [trend, warnings]); trendRow.spacing = 12
        let buttons = NSStackView(views: [authorize, settings, retry]); buttons.spacing = 10
        status.setAccessibilityLabel("温控状态"); status.identifier = NSUserInterfaceItemIdentifier("fans.status")
        let caution = NSTextField(wrappingLabelWithString: "关闭后恢复系统自动控制。CPU 温度不代表 GPU 等全部热源，系统热压力异常时自动让出控制。请勿同时运行其他风扇控制软件。未验证机型无法启用。")
        caution.font = .systemFont(ofSize: 12); caution.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, note, displayRow, switchRow, temperature, readings, trendRow, thresholds, explanation, buttons, status, caution])
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
        manager.shouldMonitor = { [weak self] in self?.trendWindow?.isVisible == true || (self?.window?.isVisible == true && self?.isHiddenOrHasHiddenAncestor == false) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func refresh() {
        warnings.state = manager.warningsEnabled ? .on : .off
        if trendWindow?.isVisible == true { trendWindow?.contentView?.needsDisplay = true }
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
    @objc private func changeWarnings() { manager.setWarnings(warnings.state == .on) }
    @objc private func showTrend() {
        if trendWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 304), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = AppLanguage.english ? "Fan trends · Last 15 minutes" : "温控曲线 · 近 15 分钟"
            panel.isReleasedWhenClosed = false; panel.contentView = FanTrendView(manager: manager)
            panel.center(); trendWindow = panel
        }
        trendWindow?.makeKeyAndOrderFront(nil); manager.poll()
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

@MainActor
private final class FanTrendView: NSView {
    let manager: FanControlManager
    init(manager: FanControlManager) { self.manager = manager; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) {
        let end = Date()
        let samples = manager.history.filter { (0...900).contains(end.timeIntervalSince($0.time)) }
        let english = AppLanguage.english
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ color: NSColor = .secondaryLabelColor) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12)])
        }
        guard !samples.isEmpty else { label(english ? "Waiting for readings…" : "等待实际采样…", 20, bounds.midY); return }
        let span = min(900.0, max(60.0, ceil(end.timeIntervalSince(samples[0].time) / 60) * 60))
        let ids = Set(samples.flatMap { $0.speeds.keys }).sorted()
        let rpmMax = max(1000, ceil((samples.flatMap { $0.speeds.values }.max() ?? 0) / 1000) * 1000)
        func graph(_ y: CGFloat, _ maxY: Double, _ title: String, _ series: [(NSColor, (FanHistorySample) -> Double?)]) {
            let rect = NSRect(x: 48, y: y, width: bounds.width - 68, height: 76)
            label(title, 16, rect.maxY + 5, .labelColor)
            for fraction in [0.0, 0.5, 1.0] {
                let level = y + rect.height * fraction
                label(String(Int(maxY * fraction)), 9, level - 7)
                NSColor.separatorColor.setFill()
                NSRect(x: rect.minX, y: level, width: rect.width, height: 1).fill()
            }
            for (color, value) in series {
                let line = NSBezierPath()
                var last: Date?
                color.set(); line.lineWidth = 2
                for sample in samples {
                    guard let v = value(sample) else { last = nil; continue }
                    let point = NSPoint(x: rect.maxX - rect.width * end.timeIntervalSince(sample.time) / span,
                                        y: rect.minY + rect.height * min(1, v / maxY))
                    if let last, sample.time.timeIntervalSince(last) <= 6 { line.line(to: point) }
                    else { line.move(to: point); NSBezierPath(ovalIn: NSRect(x: point.x-1.5, y: point.y-1.5, width: 3, height: 3)).fill() }
                    last = sample.time
                }
                line.stroke()
            }
        }
        graph(185, 125, (english ? "Highest CPU core temperature" : "CPU 核心最高温度") + String(format: "  %.1f °C", samples[samples.count - 1].temperature), [(.systemOrange, { $0.temperature })])
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemPink]
        graph(58, rpmMax, english ? "Measured fan speed · RPM" : "风扇实际转速 · RPM", ids.enumerated().map { n, id in (colors[n % colors.count], { $0.speeds[id] }) })
        for (n,id) in ids.enumerated() { label((english ? "Fan " : "风扇 ") + String(id+1), 50 + CGFloat(n)*78, 10, colors[n % colors.count]) }
        label("−\(Int(span / 60)) min", 46, 34); label(english ? "Now" : "现在", bounds.maxX-46, 34)
    }
}
