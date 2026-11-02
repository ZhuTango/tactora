import AppKit

/// Compact date detail column; no polling, and only submitted changes touch disk.
@MainActor
final class CalendarNotesView: NSView, NSTextFieldDelegate {
    private let store: CalendarNotesStore
    private let heading = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let input = CalendarNoteInput()
    private let submit = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var day = ""
    private var editingID: UUID?
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    init(store: CalendarNotesStore) {
        self.store = store
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("calendar.notes")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        let close = actionButton("xmark", label: AppLanguage.english ? "Close notes" : "收起事项", action: #selector(closeNotes))
        close.identifier = NSUserInterfaceItemIdentifier("calendar.notes.close")
        let header = NSStackView(views: [heading, NSView(), close]); header.alignment = .centerY
        input.placeholderString = AppLanguage.english ? "Type a task, then press Return" : "输入事项，回车保存"
        input.identifier = NSUserInterfaceItemIdentifier("calendar.notes.input")
        input.setAccessibilityLabel(AppLanguage.english ? "Task text" : "事项内容")
        input.font = .systemFont(ofSize: 13); input.bezelStyle = .roundedBezel
        input.delegate = self
        submit.title = AppLanguage.english ? "Add" : "添加"
        submit.bezelStyle = .rounded; submit.target = self; submit.action = #selector(saveInput)
        submit.identifier = NSUserInterfaceItemIdentifier("calendar.notes.add")
        let composer = NSStackView(views: [input, submit]); composer.spacing = 8
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setAccessibilityRole(.staticText)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = CalendarNotesDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(list)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.documentView = document
        let top = NSStackView(views: [header, summary, composer, status])
        top.orientation = .vertical; top.alignment = .leading; top.spacing = 10
        for view in [top, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 16), top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: top.widthAnchor), composer.widthAnchor.constraint(equalTo: top.widthAnchor), status.widthAnchor.constraint(equalTo: top.widthAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor), list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill(); dirtyRect.fill()
        NSColor.separatorColor.setFill(); NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
    func show(date: Date, calendar: Calendar, focus: Bool = false) {
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
        render()
        if focus { window?.makeFirstResponder(input) }
    }
    func focusInput() { window?.makeFirstResponder(input) }
    private func render() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let entries = store.entries(on: day)
        let remaining = entries.filter { !$0.completed }.count
        summary.stringValue = AppLanguage.english ? "\(remaining) pending · \(entries.count) total" : "\(remaining) 项待办 · 共 \(entries.count) 项"
        submit.title = editingID == nil ? (AppLanguage.english ? "Add" : "添加") : (AppLanguage.english ? "Save" : "保存")
        status.textColor = store.loadError == nil ? .secondaryLabelColor : .systemRed
        status.stringValue = store.loadError == nil
            ? (editingID == nil ? (AppLanguage.english ? "Saved on this Mac · Return to add" : "仅保存在本机 · 回车连续添加") : (AppLanguage.english ? "Editing · Esc to cancel" : "编辑中 · Esc 取消编辑"))
            : (AppLanguage.english ? "Could not read notes. Original file preserved." : "事项文件读取失败，原文件已保留，暂不能修改。")
        input.isEnabled = store.loadError == nil; submit.isEnabled = store.loadError == nil
        if entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Nothing planned yet.\nWrite something to remember above." : "这一天还没有事项\n在上方记下要做的事")
            empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty); empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        for item in entries {
            let row = CalendarNoteRow(item: item)
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
            saveInput(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), editingID != nil {
            editingID = nil; store.draftEditingIDs.removeValue(forKey: day)
            input.stringValue = ""; store.drafts.removeValue(forKey: day); render(); return true
        }
        return false
    }
    @objc private func saveInput() {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        saveText()
    }
    private func saveText() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if let id = editingID, let item = store.entries(on: day).first(where: { $0.id == id }) {
                try store.update(id, text: text, completed: item.completed, on: day)
            } else { try store.add(text, on: day) }
            editingID = nil; store.draftEditingIDs.removeValue(forKey: day)
            input.stringValue = ""; store.drafts.removeValue(forKey: day)
            render(); onChange?(); focusInput()
        } catch { showError() }
    }
    private func edit(_ item: CalendarNote) {
        if editingID == item.id { focusInput(); return }
        let current = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = editingID.flatMap { id in store.entries(on: day).first { $0.id == id }?.text }
        if !current.isEmpty && current != original {
            status.textColor = .secondaryLabelColor
            status.stringValue = AppLanguage.english ? "Save or clear the current draft before editing another item." : "请先保存或清空当前草稿，再编辑其他事项。"
            focusInput(); return
        }
        editingID = item.id; store.draftEditingIDs[day] = item.id
        input.stringValue = item.text; store.drafts[day] = item.text
        render(); focusInput()
    }
    private func change(_ item: CalendarNote, completed: Bool) {
        do { try store.update(item.id, text: item.text, completed: completed, on: day); render(); onChange?() }
        catch { render(); showError() }
    }
    private func delete(_ item: CalendarNote) {
        do {
            try store.remove(item.id, on: day)
            if editingID == item.id { editingID = nil; store.draftEditingIDs.removeValue(forKey: day); input.stringValue = ""; store.drafts.removeValue(forKey: day) }
            render(); onChange?()
        } catch { showError() }
    }
    private func showError() {
        status.textColor = .systemRed
        status.stringValue = AppLanguage.english ? "Could not save. Your input is still here." : "保存失败，输入内容已保留，请检查磁盘权限。"
    }
    @objc private func closeNotes() { window?.makeFirstResponder(superview); onClose?() }
    private func actionButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label)
        return button
    }
}

@MainActor
private final class CalendarNoteRow: NSView {
    var onToggle: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    init(item: CalendarNote) {
        super.init(frame: .zero)
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle))
        check.state = item.completed ? .on : .off
        check.setAccessibilityLabel((AppLanguage.english ? "Complete: " : "完成：") + item.text)
        check.identifier = NSUserInterfaceItemIdentifier("calendar.note.toggle.\(item.id)")
        let text = NSTextField(wrappingLabelWithString: item.text)
        text.font = .systemFont(ofSize: 13); text.isSelectable = true
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
        let row = NSStackView(views: [check, text, edit, delete]); row.spacing = 6; row.alignment = .top; row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func toggle() { onToggle?() }
    @objc private func edit() { onEdit?() }
    @objc private func delete() { onDelete?() }
}
private final class CalendarNotesDocumentView: NSView { override var isFlipped: Bool { true } }
private final class CalendarNoteInput: NSTextField {
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
