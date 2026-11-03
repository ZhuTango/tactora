import AppKit

/// Right-side hover preview and pinned quick-entry panel; no polling, and only submitted changes touch disk.
@MainActor
final class CalendarNotesView: NSView, NSTextFieldDelegate {
    private let store: CalendarNotesStore
    private let heading = NSTextField(labelWithString: "")
    private let dateInfo = NSTextField(wrappingLabelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let input = CalendarNoteInput()
    private var quickAdd: NSButton?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let composer = NSStackView()
    private var preview = false
    private var tracking: NSTrackingArea?
    private var day = ""
    private var editingID: UUID?
    private var rowDrafts: [UUID: String] {
        get { store.inlineDrafts }
        set { store.inlineDrafts = newValue }
    }
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    var onAdd: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    init(store: CalendarNotesStore) {
        self.store = store
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("calendar.notes")
        wantsLayer = true
        layer?.cornerRadius = 16; layer?.borderWidth = 1
        layer?.shadowOpacity = 0; layer?.shadowRadius = 12; layer?.shadowOffset = NSSize(width: 0, height: -3)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        dateInfo.font = .systemFont(ofSize: 11)
        dateInfo.textColor = .secondaryLabelColor
        dateInfo.identifier = NSUserInterfaceItemIdentifier("calendar.notes.dateInfo")
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        let close = actionButton("xmark", label: AppLanguage.english ? "Close notes" : "收起事项", action: #selector(closeNotes))
        close.identifier = NSUserInterfaceItemIdentifier("calendar.notes.close")
        let add = actionButton("plus", label: AppLanguage.english ? "Quick add" : "快速添加", action: #selector(addNote))
        quickAdd = add
        add.identifier = NSUserInterfaceItemIdentifier("calendar.notes.quickAdd")
        let header = NSStackView(views: [heading, NSView(), add, close]); header.alignment = .centerY; header.spacing = 6
        input.placeholderString = AppLanguage.english ? "Type a task, then press Return" : "输入事项，回车保存"
        input.identifier = NSUserInterfaceItemIdentifier("calendar.notes.input")
        input.setAccessibilityLabel(AppLanguage.english ? "Task text" : "事项内容")
        input.font = .systemFont(ofSize: 13); input.bezelStyle = .roundedBezel
        input.delegate = self
        input.heightAnchor.constraint(equalToConstant: 30).isActive = true
        composer.addArrangedSubview(input)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setAccessibilityRole(.staticText)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = CalendarNotesDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(list)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.documentView = document
        let top = NSStackView(views: [header, dateInfo, summary, composer, status])
        top.orientation = .vertical; top.alignment = .leading; top.spacing = 10
        for view in [top, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 12), top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: top.widthAnchor), dateInfo.widthAnchor.constraint(equalTo: top.widthAnchor), composer.widthAnchor.constraint(equalTo: top.widthAnchor), status.widthAnchor.constraint(equalTo: top.widthAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor), list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { if preview { onAdd?() } else { super.mouseDown(with: event) } }
    @objc private func addNote() { onAdd?() }
    func show(date: Date, calendar: Calendar, preview: Bool = false, showHolidays: Bool = false, focus: Bool = false) {
        self.preview = preview
        composer.isHidden = preview
        quickAdd?.isHidden = !preview
        let key = CalendarNotesStore.dayKey(date, calendar: calendar)
        if day != key {
            day = key
            editingID = store.draftEditingIDs[key]
            input.stringValue = store.drafts[key] ?? ""
            scroll.contentView.scroll(to: .zero)
        }
        let formatter = DateFormatter(); formatter.calendar = calendar
        formatter.locale = AppLanguage.english ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone; formatter.setLocalizedDateFormatFromTemplate("MMMd EEE")
        heading.stringValue = formatter.string(from: date)
        var details = [LunarDate(date, timeZone: calendar.timeZone).fullLabel]
        if let term = SolarTerms.label(on: date, calendar: calendar) { details.append(term) }
        if showHolidays, let holiday = ChinaHolidays.entry(on: date, calendar: calendar) { details.append(holiday.label) }
        dateInfo.stringValue = details.joined(separator: " · ")
        render()
        if focus { window?.makeFirstResponder(input) }
    }
    func focusInput() { window?.makeFirstResponder(input) }
    private func render() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let entries = store.entries(on: day)
        let remaining = entries.filter { !$0.completed }.count
        summary.stringValue = AppLanguage.english ? "\(entries.count) notes · \(remaining) pending" : "\(entries.count) 项 · \(remaining) 项未完成"
        summary.stringValue += preview ? (AppLanguage.english ? " · Click to pin" : " · 点击固定") : ""
        status.isHidden = store.loadError == nil && editingID == nil
        status.textColor = store.loadError == nil ? .secondaryLabelColor : .systemRed
        status.stringValue = store.loadError == nil
            ? (editingID == nil ? (AppLanguage.english ? "Saved on this Mac · Return to add" : "仅保存在本机 · 回车连续添加") : (AppLanguage.english ? "Editing · Esc to cancel" : "编辑中 · Esc 取消编辑"))
            : (AppLanguage.english ? "Could not read notes. Original file preserved." : "事项文件读取失败，原文件已保留，暂不能修改。")
        input.isEnabled = store.loadError == nil
        if entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: AppLanguage.english ? (preview ? "No tasks. Click the date to add." : "Nothing planned yet.\nWrite something to remember above.") : (preview ? "暂无事项，点击日期即可添加" : "这一天还没有事项\n在上方记下要做的事"))
            empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty); empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        for item in entries {
            let row = CalendarNoteRow(item: item, preview: preview, draft: !preview && editingID == item.id ? (rowDrafts[item.id] ?? item.text) : nil)
            row.onDraft = { [weak self] text in self?.rowDrafts[item.id] = text }
            row.onSave = { [weak self] text in self?.saveRow(item, text: text) }
            row.onCancel = { [weak self] in
                guard let self else { return }; self.rowDrafts.removeValue(forKey: item.id); self.editingID = nil; self.store.draftEditingIDs.removeValue(forKey: self.day); self.render()
            }
            row.onToggle = { [weak self] in self?.change(item, completed: !item.completed) }
            row.onEdit = { [weak self] in self?.edit(item) }
            row.onDelete = { [weak self] in self?.delete(item) }
            list.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
    func controlTextDidChange(_ notification: Notification) { store.drafts[day] = input.stringValue }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard !textView.hasMarkedText() else { return false }
            saveText(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeNotes(); return true
        }
        return false
    }
    private func saveText() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try store.add(text, on: day)
            input.stringValue = ""; store.drafts.removeValue(forKey: day)
            render(); onChange?(); focusInput()
        } catch { showError() }
    }
    private func edit(_ item: CalendarNote) {
        editingID = item.id; store.draftEditingIDs[day] = item.id
        if rowDrafts[item.id] == nil { rowDrafts[item.id] = item.text }
        render(); layoutSubtreeIfNeeded()
        if let row = list.arrangedSubviews.compactMap({ $0 as? CalendarNoteRow }).first(where: { $0.inlineInput != nil }) {
            row.scrollToVisible(row.bounds)
            window?.makeFirstResponder(row.inlineInput)
        }
    }
    private func saveRow(_ item: CalendarNote, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try store.update(item.id, text: value, completed: item.completed, on: day)
            rowDrafts.removeValue(forKey: item.id); editingID = nil; store.draftEditingIDs.removeValue(forKey: day)
            render(); onChange?()
        } catch { showError() }
    }
    private func change(_ item: CalendarNote, completed: Bool) {
        do { try store.update(item.id, text: item.text, completed: completed, on: day); render(); onChange?() }
        catch { render(); showError() }
    }
    private func delete(_ item: CalendarNote) {
        do {
            try store.remove(item.id, on: day)
            rowDrafts.removeValue(forKey: item.id)
            if editingID == item.id { editingID = nil; store.draftEditingIDs.removeValue(forKey: day) }
            render(); onChange?()
        } catch { showError() }
    }
    private func showError() {
        status.isHidden = false
        status.textColor = .systemRed
        status.stringValue = AppLanguage.english ? "Could not save. Your input is still here." : "保存失败，输入内容已保留，请检查磁盘权限。"
    }
    @objc private func closeNotes() { window?.makeFirstResponder(superview); onClose?() }
    private func actionButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

@MainActor
private final class CalendarNoteRow: NSView, NSTextFieldDelegate {
    var inlineInput: NSTextField?
    var onDraft: ((String) -> Void)?
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onToggle: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    init(item: CalendarNote, preview: Bool, draft: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle))
        check.state = item.completed ? .on : .off
        check.isEnabled = !preview
        check.widthAnchor.constraint(equalToConstant: 18).isActive = true
        check.setAccessibilityLabel((AppLanguage.english ? "Complete: " : "完成：") + item.text)
        check.identifier = NSUserInterfaceItemIdentifier("calendar.note.toggle.\(item.id)")
        let text = NSTextField(wrappingLabelWithString: item.text)
        text.font = .systemFont(ofSize: 13); text.isSelectable = !preview; text.alignment = .left
        text.identifier = NSUserInterfaceItemIdentifier("calendar.note.text.\(item.id)")
        text.textColor = item.completed ? .secondaryLabelColor : .labelColor
        if item.completed { text.attributedStringValue = NSAttributedString(string: item.text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue]) }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let edit = NSButton(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: AppLanguage.english ? "Edit" : "编辑")!, target: self, action: #selector(edit))
        let delete = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: AppLanguage.english ? "Delete" : "删除")!, target: self, action: #selector(delete))
        edit.identifier = NSUserInterfaceItemIdentifier("calendar.note.edit.\(item.id)")
        delete.identifier = NSUserInterfaceItemIdentifier("calendar.note.delete.\(item.id)")
        edit.toolTip = AppLanguage.english ? "Edit" : "编辑"; delete.toolTip = AppLanguage.english ? "Delete" : "删除"
        for button in [edit, delete] { button.isBordered = false; button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 24).isActive = true }
        let marker = NSTextField(labelWithString: item.completed ? "✓" : "•")
        marker.font = .systemFont(ofSize: 12); marker.textColor = .secondaryLabelColor
        marker.widthAnchor.constraint(equalToConstant: 14).isActive = true
        var content: NSView = text
        if let draft {
            let field = CalendarNoteInput()
            field.stringValue = draft; field.font = .systemFont(ofSize: 13); field.bezelStyle = .roundedBezel
            field.identifier = NSUserInterfaceItemIdentifier("calendar.note.input.\(item.id)")
            field.setAccessibilityLabel(AppLanguage.english ? "Edit task" : "编辑事项")
            field.toolTip = AppLanguage.english ? "Return to save · Esc to cancel" : "回车保存 · Esc 取消"
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.delegate = self; inlineInput = field; content = field
            edit.isHidden = true
        }
        let row = NSStackView(views: preview ? [marker, content] : [check, content, edit, delete]); row.spacing = 6; row.alignment = .centerY; row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    func controlTextDidChange(_ notification: Notification) {
        if let input = inlineInput { onDraft?(input.stringValue) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)), let input = inlineInput {
            onDraft?(input.stringValue); onSave?(input.stringValue); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }
    @objc private func toggle() { onToggle?() }
    @objc private func edit() { onEdit?() }
    @objc private func delete() { onDelete?() }
}
private final class CalendarNotesDocumentView: NSView { override var isFlipped: Bool { true } }
private final class CalendarNoteInput: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = CalendarNoteInputCell(textCell: "")
        isEditable = true; isSelectable = true; isBezeled = true; drawsBackground = true
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]) == .command, let editor = currentEditor() as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil); return true
            case "c": editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "a": editor.selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Align the placeholder, rendered text and field editor to the same vertical inset.
private final class CalendarNoteInputCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = min(result.height, (font?.ascender ?? 13) - (font?.descender ?? -3) + 2)
        result.origin.y += (result.height - height) / 2
        result.size.height = height
        return result
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}
