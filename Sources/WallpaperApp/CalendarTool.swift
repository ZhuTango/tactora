import AppKit

@MainActor
final class CalendarTool: NSObject {
    let defaults: UserDefaults
    private(set) var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var midnight: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var onSettings: (() -> Void)?
    var firstWeekday: Int { defaults.integer(forKey: "calendar.firstWeekday") == 1 ? 1 : 2 }
    var showWeeks: Bool { defaults.bool(forKey: "calendar.showWeeks") }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    func refresh() {
        stop()
        guard ToolFeature.calendar.isEnabled(in: defaults) else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self; item.button?.action = #selector(toggle)
        for name in [Notification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemClockDidChange] {
            watch(.default, name)
        }
        watch(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        updateDate()
    }
    private func watch(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDate() }
        }
        observers.append((center, token))
    }
    /// Template artwork lets macOS tint the date and outline together in any menu bar appearance.
    static func dateIcon(day: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 17, height: 16), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.25; outline.stroke()
            let binding = NSBezierPath()
            binding.lineWidth = 1.5; binding.lineCapStyle = .round
            for x: CGFloat in [6, 14] {
                binding.move(to: NSPoint(x: x, y: 16)); binding.line(to: NSPoint(x: x, y: 19))
            }
            binding.stroke()
            let text = NSAttributedString(string: String(day), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.black
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: (20 - size.width) / 2, y: 3 + (11 - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
    private func updateDate() {
        guard let button = statusItem?.button else { return }
        let now = Date(), model = CalendarMonth(containing: now, firstWeekday: firstWeekday)
        button.image = Self.dateIcon(day: model.calendar.component(.day, from: now))
        button.imagePosition = .imageOnly
        button.title = ""
        let formatter = DateFormatter(); formatter.locale = AppLanguage.english ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        formatter.calendar = model.calendar; formatter.dateStyle = .full
        button.toolTip = formatter.string(from: now)
        button.setAccessibilityLabel((AppLanguage.english ? "Calendar, " : "日历，") + formatter.string(from: now))
        (popover.contentViewController?.view as? CalendarPanel)?.reload()
        midnight?.invalidate()
        let next = model.calendar.date(byAdding: .day, value: 1, to: model.calendar.startOfDay(for: now))!
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDate() }
        }
        timer.tolerance = 1
        midnight = timer; RunLoop.main.add(timer, forMode: .common)
    }
    @objc func toggle() {
        guard ToolFeature.calendar.isEnabled(in: defaults), let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        let panel = CalendarPanel(firstWeekday: firstWeekday, showWeeks: showWeeks)
        panel.onClose = { [weak self] in self?.popover.performClose(nil) }
        panel.onSettings = { [weak self] in self?.popover.performClose(nil); self?.onSettings?() }
        let controller = NSViewController(); controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = panel.frame.size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        panel.window?.makeFirstResponder(panel)
    }
    func stop() {
        popover.performClose(nil); popover.contentViewController = nil
        midnight?.invalidate(); midnight = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}

@MainActor
final class CalendarPanel: NSView {
    private let firstWeekday: Int
    private let showWeeks: Bool
    private(set) var selectedDate: Date
    private var month: Date
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init(firstWeekday: Int, showWeeks: Bool, date: Date = Date()) {
        self.firstWeekday = firstWeekday; self.showWeeks = showWeeks
        selectedDate = date; month = date
        super.init(frame: NSRect(x: 0, y: 0, width: showWeeks ? 338 : 310, height: 370))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        let previous = icon("chevron.left", label: AppLanguage.english ? "Previous month" : "上个月", action: #selector(previousMonth))
        let next = icon("chevron.right", label: AppLanguage.english ? "Next month" : "下个月", action: #selector(nextMonth))
        let today = CalendarDayButton(title: AppLanguage.english ? "Today" : "今天", target: self, action: #selector(goToday))
        today.identifier = NSUserInterfaceItemIdentifier("calendar.today")
        today.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let spacer = NSView()
        let header = NSStackView(views: [heading, spacer, previous, next]); header.spacing = 4
        heading.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        grid.orientation = .vertical; grid.spacing = 4
        let settings = icon("gearshape", label: AppLanguage.english ? "Calendar settings" : "日历设置", action: #selector(settings))
        let footer = NSStackView(views: [today, NSView(), settings]); footer.spacing = 8
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [header, grid, separator, detail, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        reload()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func icon(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = CalendarDayButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
    func reload() {
        let model = CalendarMonth(containing: month, firstWeekday: firstWeekday)
        let formatter = DateFormatter(); formatter.locale = AppLanguage.english ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        formatter.calendar = model.calendar; formatter.timeZone = model.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        heading.stringValue = formatter.string(from: model.start)
        for view in grid.arrangedSubviews { grid.removeArrangedSubview(view); view.removeFromSuperview() }
        let weekdays = formatter.shortStandaloneWeekdaySymbols!
        func label(_ text: String) -> NSTextField {
            let value = NSTextField(labelWithString: text); value.alignment = .center
            value.font = .systemFont(ofSize: 11, weight: .medium); value.textColor = .secondaryLabelColor
            return value
        }
        func row(_ views: [NSView]) {
            let row = NSStackView(views: views); row.spacing = 4; row.distribution = .fillEqually
            grid.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        row((showWeeks ? [label(AppLanguage.english ? "Wk" : "周")] : []) + (0..<7).map { label(weekdays[($0 + firstWeekday - 1) % 7]) })
        formatter.dateStyle = .full; formatter.timeStyle = .none
        for week in 0..<6 {
            var cells: [NSView] = showWeeks ? [label(String(model.weekNumbers[week]))] : []
            for offset in 0..<7 {
                let index = week * 7 + offset, date = model.days[index]
                let button = CalendarDayButton(title: String(model.calendar.component(.day, from: date)), target: self, action: #selector(selectDay(_:)))
                button.tag = index
                button.identifier = NSUserInterfaceItemIdentifier("calendar.day.\(index)")
                button.selected = model.calendar.isDate(date, inSameDayAs: selectedDate)
                button.today = model.calendar.isDateInToday(date)
                button.dimmed = !model.contains(date)
                button.toolTip = formatter.string(from: date)
                button.setAccessibilityLabel(formatter.string(from: date) + (button.today ? (AppLanguage.english ? ", Today" : "，今天") : ""))
                button.setAccessibilityValue(button.selected ? (AppLanguage.english ? "Selected" : "已选中") : "")
                cells.append(button)
            }
            row(cells)
        }
        detail.stringValue = formatter.string(from: selectedDate)
    }
    @objc private func selectDay(_ sender: NSButton) {
        let model = CalendarMonth(containing: month, firstWeekday: firstWeekday)
        selectedDate = model.days[sender.tag]; month = selectedDate; reload()
        window?.makeFirstResponder(self)
    }
    func moveMonth(_ delta: Int) {
        month = CalendarMonth(containing: month, firstWeekday: firstWeekday).moving(months: delta)
        selectedDate = month; reload()
    }
    @objc private func previousMonth() { moveMonth(-1) }
    @objc private func nextMonth() { moveMonth(1) }
    @objc private func goToday() { selectedDate = Date(); month = selectedDate; reload() }
    @objc private func settings() { onSettings?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        if event.keyCode == 116 { moveMonth(-1); return }
        if event.keyCode == 121 { moveMonth(1); return }
        if event.charactersIgnoringModifiers?.lowercased() == "t" { goToday(); return }
        let steps: [UInt16: Int] = [123: -1, 124: 1, 125: 7, 126: -7]
        if let step = steps[event.keyCode], event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            selectedDate = CalendarMonth(containing: month).calendar.date(byAdding: .day, value: step, to: selectedDate)!
            month = selectedDate; reload(); return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class CalendarDayButton: NSButton {
    var selected = false
    var today = false
    var dimmed = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); isBordered = false; focusRingType = .exterior }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        if selected || hovering || isHighlighted {
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08)).setFill(); path.fill()
        }
        if today { NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke() }
        let color: NSColor = selected ? .white : dimmed ? .tertiaryLabelColor : .labelColor
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: today || selected ? .semibold : .regular), .foregroundColor: color])
        contentTintColor = color
        super.draw(dirtyRect)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: max(28, super.intrinsicContentSize.width), height: 28) }
}

@MainActor
final class CalendarSettingsView: NSView {
    private let manager: CalendarTool
    private let firstDay = NSPopUpButton()
    private let weeks = NSButton(checkboxWithTitle: AppLanguage.english ? "Show ISO week numbers" : "显示 ISO 周数", target: nil, action: nil)
    init(manager: CalendarTool) {
        self.manager = manager
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "Calendar" : "日历")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: AppLanguage.english ? "A small calendar in your menu bar. No calendar permission or network access needed." : "点击菜单栏日期查看月历，无需日历权限，也不联网。")
        note.textColor = .secondaryLabelColor
        firstDay.addItems(withTitles: AppLanguage.english ? ["Monday", "Sunday"] : ["周一", "周日"])
        firstDay.selectItem(at: manager.firstWeekday == 1 ? 1 : 0)
        firstDay.identifier = NSUserInterfaceItemIdentifier("calendar.firstWeekday")
        firstDay.setAccessibilityLabel(AppLanguage.english ? "First day of week" : "每周起始日")
        firstDay.target = self; firstDay.action = #selector(change)
        weeks.state = manager.showWeeks ? .on : .off; weeks.target = self; weeks.action = #selector(change)
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Week starts on" : "每周起始日"), firstDay]); row.spacing = 16
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Arrow keys select dates · Page Up / Down change months · T returns to today · Esc closes. Click outside to dismiss." : "方向键选择日期 · Page Up / Down 切换月份 · T 回到今天 · Esc 关闭。点击面板外自动收起。")
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 12)
        let open = NSButton(title: AppLanguage.english ? "Open calendar" : "打开日历", target: self, action: #selector(openCalendar))
        let stack = NSStackView(views: [title, note, row, weeks, hint, open])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), note.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func change() {
        manager.defaults.set(firstDay.indexOfSelectedItem == 1 ? 1 : 2, forKey: "calendar.firstWeekday")
        manager.defaults.set(weeks.state == .on, forKey: "calendar.showWeeks")
        manager.refresh()
    }
    @objc private func openCalendar() { manager.toggle() }
}
