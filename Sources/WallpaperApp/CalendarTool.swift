import AppKit

@MainActor
final class CalendarTool: NSObject, NSPopoverDelegate {
    let defaults: UserDefaults
    private(set) var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private lazy var notesStore = CalendarNotesStore(fileURL: CalendarNotesStore.defaultURL)
    private var outsideMonitors: [Any] = []
    private var midnight: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var onSettings: (() -> Void)?
    var firstWeekday: Int { defaults.integer(forKey: "calendar.firstWeekday") == 1 ? 1 : 2 }
    var showHolidays: Bool { defaults.bool(forKey: "calendar.showHolidays") }
    var notesEnabled: Bool { defaults.bool(forKey: "calendar.notesEnabled") }
    var showWeeks: Bool { defaults.bool(forKey: "calendar.showWeeks") }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        popover.behavior = .semitransient
        popover.delegate = self
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
        if popover.isShown { closeCalendar(); return }
        let panel = CalendarPanel(firstWeekday: firstWeekday, showWeeks: showWeeks, showHolidays: showHolidays, notesEnabled: notesEnabled, notesStore: notesStore)
        panel.onSizeChange = { [weak self] size in self?.popover.contentSize = size }
        panel.onClose = { [weak self] in self?.closeCalendar() }
        panel.onSettings = { [weak self] in self?.closeCalendar(); self?.onSettings?() }
        let controller = NSViewController(); controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = panel.frame.size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        panel.window?.makeFirstResponder(panel)
        monitorOutsideClicks()
    }
    private func closeCalendar() {
        clearOutsideMonitors()
        (popover.contentViewController?.view as? CalendarPanel)?.dismissNotes()
        popover.close()
    }
    private func monitorOutsideClicks() {
        clearOutsideMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            let calendar = self.popover.contentViewController?.view as? CalendarPanel
            if calendar?.containsCalendarWindow(event.window) != true && event.window !== self.statusItem?.button?.window {
                self.closeCalendar()
            }
            return event
        }) { outsideMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.closeCalendar()
        }) { outsideMonitors.append(global) }
    }
    private func clearOutsideMonitors() {
        outsideMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideMonitors.removeAll()
    }
    func popoverDidClose(_ notification: Notification) {
        clearOutsideMonitors()
        (popover.contentViewController?.view as? CalendarPanel)?.dismissNotes()
    }
    func stop() {
        clearOutsideMonitors()
        closeCalendar(); popover.contentViewController = nil
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
    private let showHolidays: Bool
    private let notesEnabled: Bool
    private let notesStore: CalendarNotesStore
    private lazy var notesView = CalendarNotesView(store: notesStore)
    private var notesWindow: CalendarNotesPanel?
    private var notesVisible = false
    private var notesEditing = false
    private var notesDate: Date?
    private var notesAnchor = NSRect.zero
    private var hoverTimer: Timer?
    private var hoverGeneration = 0
    private var hoveredDate: Date?
    private var calendarWidth: CGFloat { showWeeks ? 338 : 310 }
    private(set) var selectedDate: Date
    private(set) var month: Date
    private let heading = NSButton(title: "", target: nil, action: nil)
    private enum SelectionMode { case days, years, months }
    private var selectionMode: SelectionMode = .days
    private var selectionYear = 2026
    private var yearPage = 2020
    private var selectionHeight: CGFloat = 0
    private let detail = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    var onSizeChange: ((NSSize) -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init(firstWeekday: Int, showWeeks: Bool, showHolidays: Bool = false, notesEnabled: Bool = false, date: Date = Date(), notesStore: CalendarNotesStore? = nil) {
        self.firstWeekday = firstWeekday; self.showWeeks = showWeeks; self.showHolidays = showHolidays
        self.notesStore = notesStore ?? CalendarNotesStore()
        self.notesEnabled = notesEnabled
        selectedDate = date; month = date
        super.init(frame: NSRect(x: 0, y: 0, width: showWeeks ? 338 : 310, height: 332))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.isBordered = false; heading.alignment = .left
        heading.target = self; heading.action = #selector(toggleMonthPicker)
        heading.identifier = NSUserInterfaceItemIdentifier("calendar.chooseMonth")
        heading.toolTip = AppLanguage.english ? "Choose year and month" : "选择年份和月份"
        heading.setAccessibilityLabel(heading.toolTip)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        let previous = icon("chevron.left", label: AppLanguage.english ? "Previous month" : "上个月", action: #selector(previousMonth))
        let next = icon("chevron.right", label: AppLanguage.english ? "Next month" : "下个月", action: #selector(nextMonth))
        let today = icon("circle.fill", label: AppLanguage.english ? "Back to today" : "回到今天", action: #selector(goToday))
        today.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        previous.identifier = NSUserInterfaceItemIdentifier("calendar.previous")
        next.identifier = NSUserInterfaceItemIdentifier("calendar.next")
        today.identifier = NSUserInterfaceItemIdentifier("calendar.today")
        let spacer = NSView()
        let settings = icon("gearshape", label: AppLanguage.english ? "Calendar settings" : "日历设置", action: #selector(settings))
        settings.identifier = NSUserInterfaceItemIdentifier("calendar.settings")
        let header = NSStackView(views: [heading, spacer, settings, previous, today, next]); header.spacing = 2; header.alignment = .centerY
        heading.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        grid.orientation = .vertical; grid.spacing = 4
        let separator = NSBox(); separator.boxType = .separator
        let footer = NSStackView(views: [detail]); footer.alignment = .centerY
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, grid, separator, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.widthAnchor.constraint(equalToConstant: calendarWidth - 32),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        notesView.isHidden = true
        notesView.onChange = { [weak self] in self?.reload() }
        notesView.onClose = { [weak self] in self?.hideNotes() }
        notesView.onAdd = { [weak self] in
            guard let self, let date = self.notesDate else { return }
            self.beginQuickNote(on: date, anchor: self.notesAnchor)
        }
        notesView.onHover = { [weak self] entered in
            guard let self, !self.notesEditing else { return }
            self.cancelHover()
            if !entered { self.schedulePreviewClose() }
        }
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
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMM")
        heading.title = formatter.string(from: model.start)
        for view in grid.arrangedSubviews { grid.removeArrangedSubview(view); view.removeFromSuperview() }
        if selectionMode != .days {
            renderSelection()
            return
        }
        let weekdays = formatter.shortStandaloneWeekdaySymbols!
        func label(_ text: String) -> NSTextField {
            let value = NSTextField(labelWithString: text); value.alignment = .center
            value.font = .systemFont(ofSize: 11, weight: .medium); value.textColor = .secondaryLabelColor
            return value
        }
        func row(_ views: [NSView], height: CGFloat = 42) {
            let row = NSStackView(views: views); row.spacing = 4; row.distribution = .fillEqually
            grid.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        row((showWeeks ? [label(AppLanguage.english ? "Wk" : "周")] : []) + (0..<7).map { label(weekdays[($0 + firstWeekday - 1) % 7]) }, height: 28)
        formatter.dateStyle = .full; formatter.timeStyle = .none
        for week in 0..<model.visibleWeeks {
            var cells: [NSView] = showWeeks ? [label(String(model.weekNumbers[week]))] : []
            for offset in 0..<7 {
                let index = week * 7 + offset, date = model.days[index]
                let button = CalendarDayButton(title: String(model.calendar.component(.day, from: date)), target: self, action: #selector(selectDay(_:)))
                let lunar = LunarDate(date, timeZone: model.calendar.timeZone)
                let holiday = showHolidays ? ChinaHolidays.entry(on: date, calendar: model.calendar) : nil
                button.holiday = holiday
                let solarTerm = SolarTerms.label(on: date, calendar: model.calendar)
                button.subtitle = solarTerm ?? lunar.shortLabel
                let notes = notesEnabled ? notesStore.entries(on: CalendarNotesStore.dayKey(date, calendar: model.calendar)) : []
                button.onHover = { [weak self, weak button] entered in
                    guard let self, let button else { return }
                    self.hoverDate(date, anchor: button, entered: entered)
                }
                button.onDoubleClick = { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.layoutSubtreeIfNeeded()
                    self.beginQuickNote(on: date, anchor: self.convert(button.bounds, from: button))
                }
                button.hasNotes = notesEnabled && !notes.isEmpty
                button.allNotesCompleted = !notes.isEmpty && notes.allSatisfy { $0.completed }
                button.tag = index
                button.identifier = NSUserInterfaceItemIdentifier("calendar.day.\(index)")
                button.selected = model.calendar.isDate(date, inSameDayAs: selectedDate)
                button.today = model.calendar.isDateInToday(date)
                button.dimmed = !model.contains(date)
                button.toolTip = formatter.string(from: date) + " · " + lunar.fullLabel + (holiday.map { " · " + $0.label } ?? "") + (solarTerm.map { " · " + $0 } ?? "")
                button.setAccessibilityLabel(formatter.string(from: date) + "，" + lunar.fullLabel + (holiday.map { "，" + $0.label } ?? "") + (notes.isEmpty ? "" : (AppLanguage.english ? ", \(notes.count) notes" : "，\(notes.count) 项事项")) + (button.today ? (AppLanguage.english ? ", Today" : "，今天") : ""))
                if notesEnabled { button.toolTip = nil } // Custom hover card replaces the system tooltip.
                button.setAccessibilityValue(button.selected ? (AppLanguage.english ? "Selected" : "已选中") : "")
                cells.append(button)
            }
            row(cells)
        }
        detail.stringValue = formatter.string(from: selectedDate) + " · " + LunarDate(selectedDate).fullLabel
        if showHolidays {
            if !ChinaHolidays.supportedYears.contains(model.calendar.component(.year, from: month)) {
                detail.stringValue = AppLanguage.english ? "Holiday schedule not included for this year" : "该年放假安排暂未收录"
            } else if let holiday = ChinaHolidays.entry(on: selectedDate, calendar: model.calendar) {
                detail.stringValue = holiday.label + " · " + detail.stringValue
            }
        }
        detail.toolTip = detail.stringValue
        detail.lineBreakMode = .byTruncatingTail
        let size = NSSize(width: calendarWidth, height: 416 + CGFloat(model.visibleWeeks - 6) * 46)
        setFrameSize(size)
        onSizeChange?(size)
        if notesVisible, let date = notesDate {
            notesView.show(date: date, calendar: model.calendar, preview: !notesEditing, showHolidays: showHolidays)
            positionNotesCard()
        }
    }
    @objc private func openNotes() {
        guard notesEnabled else { return }
        layoutSubtreeIfNeeded()
        let model = CalendarMonth(containing: month, firstWeekday: firstWeekday)
        let tag = model.days.firstIndex { model.calendar.isDate($0, inSameDayAs: selectedDate) }
        let button = grid.arrangedSubviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton }.first { $0.tag == tag }
        let anchor = button.map { convert($0.bounds, from: $0) } ?? NSRect(x: 16, y: 16, width: 28, height: 28)
        beginQuickNote(on: selectedDate, anchor: anchor)
    }
    private func beginQuickNote(on date: Date, anchor: NSRect) {
        guard notesEnabled else { return }
        cancelHover(); hoveredDate = nil
        selectedDate = date; selectionMode = .days
        notesDate = date; notesAnchor = anchor; notesVisible = true; notesEditing = true
        notesView.isHidden = false
        reload(); notesWindow?.makeKey(); notesView.focusInput()
    }
    private func positionNotesCard() {
        guard let parent = window else { return }
        if notesWindow == nil {
            let panel = CalendarNotesPanel(contentRect: NSRect(x: 0, y: 0, width: 284, height: 280), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.contentView = notesView
            notesWindow = panel
        }
        guard let panel = notesWindow else { return }
        let screen = parent.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let count = notesDate.map { notesStore.entries(on: CalendarNotesStore.dayKey($0, calendar: CalendarMonth(containing: $0).calendar)).count } ?? 0
        let height: CGFloat = min(360, (notesEditing ? 180 : 130) + CGFloat(max(1, min(count, 4))) * 48)
        let parentFrame = parent.frame
        let x = parentFrame.maxX + 8 + 284 <= screen.maxX ? parentFrame.maxX + 8 : parentFrame.minX - 292
        panel.setFrame(NSRect(x: max(screen.minX, min(x, screen.maxX - 284)), y: max(screen.minY, min(parentFrame.midY - height / 2, screen.maxY - height)), width: 284, height: height), display: true)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func hoverDate(_ date: Date, anchor: NSView, entered: Bool) {
        guard notesEnabled, !notesEditing, selectionMode == .days else { return }
        cancelHover()
        if !entered {
            if hoveredDate == date { hoveredDate = nil }
            schedulePreviewClose(); return
        }
        hoveredDate = date
        let calendar = CalendarMonth(containing: date).calendar
        layoutSubtreeIfNeeded()
        let rect = convert(anchor.bounds, from: anchor)
        let generation = hoverGeneration
        let timer = Timer(timeInterval: 0.28, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, self.hoverGeneration == generation, self.hoveredDate == date, !self.notesEditing else { return }
                self.notesDate = date; self.notesAnchor = rect; self.notesVisible = true
                self.notesView.show(date: date, calendar: calendar, preview: true, showHolidays: self.showHolidays)
                self.positionNotesCard(); self.notesView.isHidden = false
            }
        }
        hoverTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func schedulePreviewClose() {
        cancelHover()
        let generation = hoverGeneration
        let timer = Timer(timeInterval: 0.22, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hoverGeneration == generation, !self.notesEditing else { return }
                self.hideNotes()
            }
        }
        hoverTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func cancelHover() {
        hoverGeneration += 1; hoverTimer?.invalidate(); hoverTimer = nil
    }
    func containsCalendarWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        return candidate === window || (notesVisible && candidate === notesWindow)
    }
    func dismissNotes() { hideNotes(restoreKeyboardFocus: false) }
    private func hideNotes(restoreKeyboardFocus: Bool = true) {
        cancelHover(); hoverTimer = nil; hoveredDate = nil
        let restoreFocus = notesEditing && restoreKeyboardFocus
        notesVisible = false; notesEditing = false; notesView.isHidden = true
        notesWindow?.parent?.removeChildWindow(notesWindow!)
        notesWindow?.orderOut(nil)
        if restoreFocus { window?.makeKey(); window?.makeFirstResponder(self) }
    }
    override func mouseDown(with event: NSEvent) {
        dismissNotes()
        onClose?()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideNotes() }
        super.viewWillMove(toWindow: newWindow)
    }
    @objc private func toggleMonthPicker() {
        hideNotes()
        let calendar = CalendarMonth(containing: month).calendar
        if selectionMode == .years {
            selectionMode = .days
        } else {
            if selectionMode == .days {
                selectionHeight = frame.height
                selectionYear = calendar.component(.year, from: month)
            }
            yearPage = max(1, ((selectionYear - 1) / 12) * 12 + 1)
            selectionMode = .years
        }
        reload()
        window?.makeFirstResponder(self)
    }
    private func renderSelection() {
        heading.title = selectionMode == .years ? "\(yearPage)–\(min(9999, yearPage + 11))" : "\(selectionYear)"
        detail.stringValue = selectionMode == .years
            ? (AppLanguage.english ? "Choose a year · Click title to return" : "选择年份 · 点击标题返回日历")
            : (AppLanguage.english ? "Choose a month · Click title to choose year" : "选择月份 · 点击标题返回年份")
        let height = (selectionHeight - 108 - 12) / 4
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.english ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        let names = formatter.shortStandaloneMonthSymbols!
        for rowIndex in 0..<4 {
            let row = NSStackView(); row.spacing = 8; row.distribution = .fillEqually
            for column in 0..<3 {
                let index = rowIndex * 3 + column
                let value = selectionMode == .years ? yearPage + index : index + 1
                let button = CalendarDayButton(title: selectionMode == .years ? String(value) : names[index], target: self, action: #selector(choosePeriod(_:)))
                button.tag = value
                button.identifier = NSUserInterfaceItemIdentifier("calendar.\(selectionMode == .years ? "year" : "month").\(value)")
                button.selected = selectionMode == .years ? value == selectionYear : selectionYear == Calendar(identifier: .gregorian).component(.year, from: month) && value == Calendar(identifier: .gregorian).component(.month, from: month)
                button.isEnabled = value <= 9999
                row.addArrangedSubview(button)
                button.heightAnchor.constraint(equalToConstant: height - 12).isActive = true
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        // Keep the existing month footprint throughout both selection steps.
        setFrameSize(NSSize(width: frame.width, height: selectionHeight))
    }
    @objc private func choosePeriod(_ sender: NSButton) {
        if selectionMode == .years {
            selectionYear = sender.tag; selectionMode = .months; reload()
        } else {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            if let date = calendar.date(from: DateComponents(year: selectionYear, month: sender.tag, day: 1, hour: 12)) { jumpToMonth(date) }
        }
    }
    func jumpToMonth(_ date: Date) {
        hideNotes()
        month = CalendarMonth(containing: date, firstWeekday: firstWeekday).start
        selectionMode = .days
        reload()
    }
    @objc private func selectDay(_ sender: NSButton) {
        let model = CalendarMonth(containing: month, firstWeekday: firstWeekday)
        layoutSubtreeIfNeeded()
        if notesEnabled { beginQuickNote(on: model.days[sender.tag], anchor: convert(sender.bounds, from: sender)) }
        else { selectedDate = model.days[sender.tag]; reload() }
    }
    func moveMonth(_ delta: Int) {
        hideNotes()
        if selectionMode == .years {
            yearPage = min(9988, max(1, yearPage + delta * 12)); reload(); return
        }
        if selectionMode == .months {
            selectionYear = min(9999, max(1, selectionYear + delta)); reload(); return
        }
        month = CalendarMonth(containing: month, firstWeekday: firstWeekday).moving(months: delta)
        reload()
    }
    @objc private func previousMonth() { moveMonth(-1) }
    @objc private func nextMonth() { moveMonth(1) }
    @objc private func goToday() { hideNotes(); selectionMode = .days; selectedDate = Date(); month = selectedDate; reload() }
    @objc private func settings() { onSettings?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && selectionMode == .days { openNotes(); return }
        if event.keyCode == 53 { if notesVisible { hideNotes(); return }; if selectionMode != .days { selectionMode = .days; reload() } else { onClose?() }; return }
        if event.keyCode == 116 { moveMonth(-1); return }
        if event.keyCode == 121 { moveMonth(1); return }
        if event.charactersIgnoringModifiers?.lowercased() == "t" { goToday(); return }
        if selectionMode != .days {
            if event.keyCode == 123 { moveMonth(-1) }
            if event.keyCode == 124 { moveMonth(1) }
            return
        }
        let steps: [UInt16: Int] = [123: -1, 124: 1, 125: 7, 126: -7]
        if let step = steps[event.keyCode], event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            hideNotes()
            selectedDate = CalendarMonth(containing: month).calendar.date(byAdding: .day, value: step, to: selectedDate)!
            month = selectedDate; reload(); return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class CalendarNotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CalendarDayButton: NSButton {
    var onHover: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var holiday: ChinaHolidays.Entry?
    var subtitle: String?
    var hasNotes = false
    var allNotesCompleted = false
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
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick { onDoubleClick(); return }
        super.mouseDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        if selected || hovering || isHighlighted {
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08)).setFill(); path.fill()
        }
        if today { NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke() }
        let color: NSColor = selected ? .white : dimmed ? .tertiaryLabelColor : .labelColor
        if let subtitle {
            let main = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: today || selected ? .semibold : .regular), .foregroundColor: color])
            let sub = NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.85) : dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor])
            main.draw(at: NSPoint(x: (bounds.width - main.size().width) / 2 - (holiday == nil ? 0 : 3), y: 4))
            if let holiday {
                let badge = NSAttributedString(string: holiday.badge, attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .semibold), .foregroundColor: selected ? NSColor.white : holiday.isWorkday ? NSColor.systemOrange : NSColor.systemRed])
                badge.draw(at: NSPoint(x: bounds.width - badge.size().width - 1, y: 3))
            }
            sub.draw(at: NSPoint(x: (bounds.width - sub.size().width) / 2, y: 22))
            if hasNotes {
                (selected ? NSColor.white : allNotesCompleted ? NSColor.secondaryLabelColor : NSColor.controlAccentColor).setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: 37, width: 3, height: 3)).fill()
            }
            return
        }
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: today || selected ? .semibold : .regular), .foregroundColor: color])
        contentTintColor = color
        super.draw(dirtyRect)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: max(28, super.intrinsicContentSize.width), height: subtitle == nil ? 28 : 42) }
}

@MainActor
final class CalendarSettingsView: NSView {
    private let manager: CalendarTool
    private let firstDay = NSPopUpButton()
    private let notes = NSButton(checkboxWithTitle: AppLanguage.english ? "Date tasks · floating preview" : "日期事项 · 悬浮预览", target: nil, action: nil)
    private let holidays = NSButton(checkboxWithTitle: AppLanguage.english ? "Show mainland China holidays" : "显示中国大陆节假日", target: nil, action: nil)
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
        notes.state = manager.notesEnabled ? .on : .off; notes.target = self; notes.action = #selector(change)
        notes.identifier = NSUserInterfaceItemIdentifier("calendar.notesEnabled")
        notes.toolTip = AppLanguage.english ? "Off by default. Existing tasks are kept when disabled." : "默认关闭；关闭后保留已有事项。"
        weeks.state = manager.showWeeks ? .on : .off; weeks.target = self; weeks.action = #selector(change)
        holidays.state = manager.showHolidays ? .on : .off; holidays.target = self; holidays.action = #selector(change)
        holidays.identifier = NSUserInterfaceItemIdentifier("calendar.showHolidays")
        let coverage = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Offline 2026 State Council schedule. 休: holiday · 班: makeup workday. Other years are not inferred; updates ship with the app." : "内置 2026 年国务院放假安排。休：放假；班：调休上班。其他年份不推算，随应用更新补充。")
        coverage.font = .systemFont(ofSize: 12); coverage.textColor = .secondaryLabelColor
        let row = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Week starts on" : "每周起始日"), firstDay]); row.spacing = 16
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Arrow keys select dates · Page Up / Down change months · T returns to today · Esc closes. Click outside to dismiss." : "方向键选择日期 · Page Up / Down 切换月份 · T 回到今天 · Esc 关闭。点击面板外自动收起。")
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 12)
        let open = NSButton(title: AppLanguage.english ? "Open calendar" : "打开日历", target: self, action: #selector(openCalendar))
        let stack = NSStackView(views: [title, note, row, weeks, notes, holidays, coverage, hint, open])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), coverage.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func change() {
        manager.defaults.set(firstDay.indexOfSelectedItem == 1 ? 1 : 2, forKey: "calendar.firstWeekday")
        manager.defaults.set(holidays.state == .on, forKey: "calendar.showHolidays")
        manager.defaults.set(notes.state == .on, forKey: "calendar.notesEnabled")
        manager.defaults.set(weeks.state == .on, forKey: "calendar.showWeeks")
        manager.refresh()
    }
    @objc private func openCalendar() { manager.toggle() }
}
