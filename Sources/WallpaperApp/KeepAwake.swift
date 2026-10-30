import AppKit
import IOKit.pwr_mgt

@MainActor
final class KeepAwake {
    static let presets = [15, 30, 60, 120, 300]
    static let maximumMinutes = 43_200
    private let defaults: UserDefaults
    private var assertion: IOPMAssertionID = 0
    private var expiryTimer: Timer?
    private(set) var deadline: Date?
    private(set) var active = false
    private(set) var selectedMinutes: Int?
    var onChange: (() -> Void)?
    var customMinutes: [Int] {
        (defaults.array(forKey: "keepAwakeDurations") as? [Int] ?? []).filter { (1...Self.maximumMinutes).contains($0) && !Self.presets.contains($0) }.sorted()
    }
    var durations: [Int] { Array(Set(Self.presets + customMinutes)).sorted() }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func label(_ minutes: Int) -> String {
        if minutes == 0 { return AppLanguage.english ? "Until stopped" : "直到手动停止" }
        if minutes % 60 == 0 { return AppLanguage.english ? "\(minutes / 60) hours" : "\(minutes / 60) 小时" }
        return AppLanguage.english ? "\(minutes) minutes" : "\(minutes) 分钟"
    }
    func addDuration(_ minutes: Int) throws {
        guard (1...Self.maximumMinutes).contains(minutes) else { throw failure("请输入 1 分钟至 30 天的时长 / Enter 1 minute to 30 days") }
        guard durations.contains(minutes) || customMinutes.count < 30 else { throw failure("最多保存 30 个自定义时长 / Up to 30 custom durations") }
        defaults.set(Array(Set(customMinutes + (Self.presets.contains(minutes) ? [] : [minutes]))).sorted(), forKey: "keepAwakeDurations")
        onChange?()
    }
    func removeDuration(_ minutes: Int) {
        defaults.set(customMinutes.filter { $0 != minutes }, forKey: "keepAwakeDurations")
        onChange?()
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "KeepAwake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func start(minutes: Int) throws {
        guard ToolFeature.awake.isEnabled(in: defaults) else { throw failure("防止休眠功能已停用 / Keep Awake is disabled") }
        guard (0...Self.maximumMinutes).contains(minutes) else { throw failure("无效时长 / Invalid duration") }
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypeNoIdleSleep,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey: "Tactora — Keep Awake"
        ]
        if minutes > 0 {
            properties[kIOPMAssertionTimeoutKey] = Double(minutes * 60)
            properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
        }
        var replacement: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &replacement)
        guard result == kIOReturnSuccess else { throw failure("无法阻止休眠 / Cannot prevent sleep (\(result))") }
        // Preserve a running session if acquiring the replacement fails.
        stop(notify: false)
        assertion = replacement
        active = true
        selectedMinutes = minutes
        deadline = minutes == 0 ? nil : Date().addingTimeInterval(Double(minutes * 60))
        if let deadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireIfNeeded() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
        onChange?()
    }
    func expireIfNeeded(now: Date = Date()) {
        if let deadline, now >= deadline { stop() }
    }
    func stop(notify: Bool = true) {
        expiryTimer?.invalidate(); expiryTimer = nil
        if active { IOPMAssertionRelease(assertion) }
        assertion = 0; active = false; deadline = nil; selectedMinutes = nil
        if notify { onChange?() }
    }
    var status: String {
        guard active else { return AppLanguage.english ? "Inactive · normal sleep behavior" : "未开启 · 按系统设置休眠" }
        guard let deadline else { return AppLanguage.english ? "Active · until stopped" : "防休眠中 · 直到手动停止" }
        let seconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        let remaining = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return (AppLanguage.english ? "Remaining " : "剩余 ") + remaining
    }
}

@MainActor
final class KeepAwakeSettingsView: NSView {
    private let manager: KeepAwake
    private let picker = NSPopUpButton()
    private let amount = NSTextField(string: "")
    private let units = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let stopButton = SettingsFeedbackButton()
    private let removeButton = SettingsFeedbackButton()
    private var timer: Timer?
    init(manager: KeepAwake) {
        self.manager = manager
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "Keep Awake" : "防止休眠")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english
            ? "Prevent idle system sleep while allowing display sleep and lid brightness control. Closing the lid or choosing Sleep may still put the Mac to sleep. Sessions end when Tactora quits."
            : "阻止电脑因空闲休眠，仍允许屏幕息屏和合盖亮度控制。合盖或主动选择休眠仍可能让电脑休眠；退出方寸即解除防休眠，重启后不会自动开启。")
        note.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        picker.setAccessibilityLabel(AppLanguage.english ? "Duration" : "防休眠时长")
        picker.target = self; picker.action = #selector(selectionChanged)
        let start = SettingsFeedbackButton(title: AppLanguage.english ? "Start / Restart" : "开始 / 重新计时", target: self, action: #selector(startSession))
        stopButton.title = AppLanguage.english ? "Stop" : "停止防休眠"
        stopButton.target = self; stopButton.action = #selector(stopSession)
        let controls = NSStackView(views: [picker, start, stopButton]); controls.spacing = 12
        let customTitle = NSTextField(labelWithString: AppLanguage.english ? "Custom durations" : "自定义时长")
        customTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        amount.placeholderString = AppLanguage.english ? "Positive integer" : "输入正整数"
        amount.setAccessibilityLabel(AppLanguage.english ? "Custom duration" : "自定义防休眠时长")
        amount.widthAnchor.constraint(equalToConstant: 140).isActive = true
        units.addItems(withTitles: AppLanguage.english ? ["Minutes", "Hours"] : ["分钟", "小时"])
        let add = SettingsFeedbackButton(title: AppLanguage.english ? "Add duration" : "添加时长", target: self, action: #selector(addDuration))
        removeButton.title = AppLanguage.english ? "Remove selected" : "删除所选时长"
        removeButton.target = self; removeButton.action = #selector(removeDuration)
        let custom = NSStackView(views: [amount, units, add, removeButton]); custom.spacing = 12
        let hint = NSTextField(labelWithString: AppLanguage.english ? "1 minute–30 days · saved locally · adding does not start a session" : "1 分钟至 30 天 · 自动保存 · 添加时长不会立即启动")
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, note, status, controls, customTitle, custom, hint, feedback])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), note.widthAnchor.constraint(equalTo: stack.widthAnchor), feedback.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        reload(selected: 60)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        if window != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    if self.window?.isVisible == true { self.refresh() }
                }
            }
            timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    private var selected: Int { picker.selectedItem?.tag ?? 60 }
    private func reload(selected: Int) {
        picker.removeAllItems()
        for value in manager.durations + [0] { picker.addItem(withTitle: KeepAwake.label(value)); picker.lastItem?.tag = value }
        picker.selectItem(withTag: selected); refresh()
    }
    private func refresh() {
        status.stringValue = manager.status
        stopButton.isEnabled = manager.active
        removeButton.isEnabled = manager.customMinutes.contains(selected)
    }
    @objc private func selectionChanged() { refresh() }
    @objc private func startSession() {
        do { try manager.start(minutes: selected); feedback.stringValue = "" }
        catch { feedback.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func stopSession() { manager.stop(); feedback.stringValue = ""; refresh() }
    @objc private func addDuration() {
        let text = amount.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), value > 0, value <= KeepAwake.maximumMinutes / (units.indexOfSelectedItem == 1 ? 60 : 1) else {
            feedback.stringValue = AppLanguage.english ? "Enter a whole duration between 1 minute and 30 days." : "请输入 1 分钟至 30 天范围内的整数时长。"; return
        }
        let minutes = value * (units.indexOfSelectedItem == 1 ? 60 : 1)
        do { try manager.addDuration(minutes); reload(selected: minutes); amount.stringValue = ""; feedback.stringValue = "" }
        catch { feedback.stringValue = error.localizedDescription }
    }
    @objc private func removeDuration() { manager.removeDuration(selected); reload(selected: 60) }
}
