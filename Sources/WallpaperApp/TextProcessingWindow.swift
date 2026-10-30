import AppKit

/// Accessory apps have no standard Edit menu to dispatch these key equivalents.
@MainActor
final class TextToolsEditor: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command || modifiers == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        if modifiers == [.command, .shift] {
            guard event.keyCode == 6 else { return super.performKeyEquivalent(with: event) }
            if isEditable, undoManager?.canRedo == true { undoManager?.redo() }
            return true
        }
        switch event.keyCode {
        case 0: selectAll(nil)
        case 8: copy(nil)
        case 7: if isEditable { cut(nil) }
        case 9: if isEditable { paste(nil) }
        case 6: if isEditable, undoManager?.canUndo == true { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor
final class TextProcessingWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let input = TextToolsEditor()
    let output = TextToolsEditor()
    let comparison = TextToolsEditor()
    private let mode = NSSegmentedControl(labels: AppLanguage.english ? ["Auto", "JSON", "Timestamp", "Compare", "Cleanup"] : ["自动识别", "JSON", "时间戳", "文本对比", "基础整理"], trackingMode: .selectOne, target: nil, action: nil)
    private var comparisonPane: NSView!
    private let detection = NSTextField(labelWithString: "")
    private let operation = NSPopUpButton()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private(set) var processing = false
    var onClose: (() -> Void)?

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        self.defaults = defaults; self.pasteboard = pasteboard
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppLanguage.english ? "Text Tools · Tactora" : "文本快捷处理 · 方寸"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 500)
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        let root = NSView(); root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        window.contentView = root
        let title = NSTextField(labelWithString: AppLanguage.english ? "Text Tools" : "文本快捷处理")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(labelWithString: AppLanguage.english ? "Local processing · Original kept · Nothing saved on close" : "本地处理 · 保留原文 · 关闭后不保存")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        let header = NSStackView(views: [title, note]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 6
        let paste = button(AppLanguage.english ? "Paste Text" : "粘贴文字", #selector(pasteInput))
        paste.identifier = NSUserInterfaceItemIdentifier("text.paste")
        let clear = button(AppLanguage.english ? "Clear" : "清空", #selector(clearInput))
        clear.identifier = NSUserInterfaceItemIdentifier("text.clear")
        let toolbar = NSStackView(views: [header, NSView(), paste, clear]); toolbar.spacing = 10
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        mode.identifier = NSUserInterfaceItemIdentifier("text.mode")
        mode.setAccessibilityLabel(AppLanguage.english ? "Text tool" : "文本工具")
        detection.textColor = .secondaryLabelColor
        detection.font = .systemFont(ofSize: 12)
        let navigation = NSStackView(views: [mode, NSView(), detection]); navigation.spacing = 12
        operation.target = self; operation.action = #selector(operationChanged)
        operation.identifier = NSUserInterfaceItemIdentifier("text.operation")
        operation.setAccessibilityLabel(AppLanguage.english ? "Text operation" : "处理方式")
        operation.widthAnchor.constraint(equalToConstant: 150).isActive = true
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
        let operationRow = NSStackView(views: [NSTextField(labelWithString: AppLanguage.english ? "Operation" : "处理方式"), operation, detail]); operationRow.spacing = 12
        comparisonPane = pane(comparison, title: AppLanguage.english ? "Revised text" : "对比文本", editable: true)
        comparison.identifier = NSUserInterfaceItemIdentifier("text.comparison")
        let panes = NSStackView(views: [pane(input, title: AppLanguage.english ? "Original" : "原文", editable: true), comparisonPane, pane(output, title: AppLanguage.english ? "Result Preview" : "结果预览", editable: false)])
        panes.spacing = 16; panes.distribution = .fillEqually
        copyButton.title = AppLanguage.english ? "Copy Result" : "复制结果"
        copyButton.target = self; copyButton.action = #selector(copyResult); copyButton.bezelStyle = .rounded
        copyButton.identifier = NSUserInterfaceItemIdentifier("text.copy")
        copyButton.contentTintColor = .controlAccentColor; copyButton.isEnabled = false
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 3
        let footer = NSStackView(views: [status, NSView(), copyButton]); footer.spacing = 12
        for view in [toolbar, navigation, operationRow, panes, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            navigation.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 20), navigation.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), navigation.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            operationRow.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 16), operationRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), operationRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            panes.topAnchor.constraint(equalTo: operationRow.bottomAnchor, constant: 18), panes.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), panes.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            footer.topAnchor.constraint(equalTo: panes.bottomAnchor, constant: 16), footer.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), footer.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        input.delegate = self; comparison.delegate = self
        modeChanged(); clearInput()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { task?.cancel() }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button
    }
    private func pane(_ editor: NSTextView, title: String, editable: Bool) -> NSView {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        editor.isRichText = false; editor.isEditable = editable; editor.isSelectable = true
        editor.allowsUndo = editable
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(title)
        editor.identifier = NSUserInterfaceItemIdentifier(editable ? "text.input" : "text.output")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder; scroll.documentView = editor
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.masksToBounds = true
        let stack = NSStackView(views: [heading, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    func present() {
        guard ToolFeature.text.isEnabled(in: defaults), let window else { return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(input)
    }
    func setInput(_ value: String) {
        guard value.utf8.count <= TextProcessor.maximumBytes else { setStatus(AppLanguage.english ? "Text exceeds 1 MB; original kept." : "文字超过 1 MB，已保留原文。"); return }
        input.string = value; input.undoManager?.removeAllActions(); schedule()
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard textView === input || textView === comparison, let replacementString else { return true }
        let removed = (textView.string as NSString).substring(with: affectedCharRange)
        let size = textView.string.utf8.count - removed.utf8.count + replacementString.utf8.count
        guard size <= TextProcessor.maximumBytes else {
            setStatus(AppLanguage.english ? "Text exceeds 1 MB; original kept." : "文字超过 1 MB，已保留原文。")
            return false
        }
        return true
    }
    func textDidChange(_ notification: Notification) { schedule() }
    @objc private func pasteInput() {
        guard let text = pasteboard.string(forType: .string) else { setStatus(AppLanguage.english ? "Clipboard has no text." : "剪贴板中没有文字。"); return }
        setInput(text)
    }
    @objc private func clearInput() {
        task?.cancel(); revision = UUID(); processing = false
        input.string = ""; comparison.string = ""; output.string = ""; input.undoManager?.removeAllActions(); comparison.undoManager?.removeAllActions()
        output.isSelectable = true; copyButton.isEnabled = false
        setStatus(AppLanguage.english ? "Paste or type text on the left." : "在左侧粘贴或输入文字。")
    }
    private var selectedMode: TextToolMode { TextToolMode(rawValue: mode.selectedSegment) ?? .automatic }
    @objc private func modeChanged() {
        operation.removeAllItems()
        switch selectedMode {
        case .json:
            operation.addItems(withTitles: AppLanguage.english ? ["Format & validate", "Compact", "Escape string", "Unescape string"] : ["格式化与校验", "压缩 JSON", "转义为字符串", "还原转义字符串"])
        case .timestamp:
            operation.addItems(withTitles: AppLanguage.english ? ["Detect unit", "Seconds", "Milliseconds"] : ["自动识别单位", "秒", "毫秒"])
        case .basic: operation.addItems(withTitles: TextOperation.allCases.map(Self.title))
        default: operation.addItem(withTitle: AppLanguage.english ? "Automatic" : "自动")
        }
        operation.isEnabled = [.json, .timestamp, .basic].contains(selectedMode)
        comparisonPane.isHidden = selectedMode != .compare
        updateDetail(); schedule()
    }
    @objc private func operationChanged() { updateDetail(); schedule() }
    private func updateDetail() {
        switch selectedMode {
        case .automatic: detail.stringValue = AppLanguage.english ? "Detect JSON or Unix timestamps; plain text is kept unchanged." : "自动识别 JSON、时间戳；普通文字保持原样，可切换到基础整理。"
        case .json: detail.stringValue = AppLanguage.english ? "Validate and transform locally. Original text stays untouched." : "本地校验与转换；格式错误会显示原因，原文不变。"
        case .timestamp: detail.stringValue = AppLanguage.english ? "Compare local time and UTC. Auto accepts 10 or 13 digits." : "同时显示本地时间与 UTC；自动识别 10 位秒、13 位毫秒。"
        case .compare: detail.stringValue = AppLanguage.english ? "Paste two versions. − removed, + added; up to 2,000 lines each." : "输入两份文本。− 删除，+ 新增；每份最多 2,000 行、128 KB。"
        case .basic:
            let details = AppLanguage.english
                ? ["Trim only the beginning and end.", "Join nonempty lines with spaces.", "Remove whitespace-only lines.", "Keep the first exact occurrence of each line.", "Convert letters to uppercase.", "Convert letters to lowercase."]
                : ["仅去掉整段文字首尾空白，保留内部排版。", "用空格连接非空行。", "移除空行及只有空白的行。", "按整行精确去重，保留首次出现顺序。", "字母转为大写。", "字母转为小写。"]
            detail.stringValue = details[max(0, operation.indexOfSelectedItem)]
        }
    }
    private func schedule() {
        task?.cancel(); revision = UUID(); let token = revision
        copyButton.isEnabled = false; output.isSelectable = false; output.textColor = .tertiaryLabelColor
        guard ToolFeature.text.isEnabled(in: defaults) else { clearInput(); return }
        guard !input.string.isEmpty || (selectedMode == .compare && !comparison.string.isEmpty) else {
            processing = false; output.string = ""; output.isSelectable = true
            output.textColor = .labelColor
            setStatus(AppLanguage.english ? "Paste or type text on the left." : "在左侧粘贴或输入文字。")
            return
        }
        let source = input.string, other = comparison.string
        let requestedMode = selectedMode
        let selected = requestedMode == .automatic ? TextWorkbench.detect(source) : requestedMode
        let index = max(0, operation.indexOfSelectedItem)
        detection.stringValue = requestedMode == .automatic ? (selected == .json ? "JSON" : selected == .timestamp ? (AppLanguage.english ? "Unix timestamp" : "Unix 时间戳") : (AppLanguage.english ? "Plain text" : "普通文本")) : ""
        guard source.utf8.count <= TextProcessor.maximumBytes else { processing = false; output.string = ""; setStatus(AppLanguage.english ? "Text exceeds 1 MB." : "文字超过 1 MB，请缩短后重试。"); return }
        processing = true; setStatus(AppLanguage.english ? "Updating preview…" : "正在更新预览…")
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { Result<String, Error> {
                switch selected {
                case .json: return try TextWorkbench.json(source, operation: JSONTextOperation(rawValue: index) ?? .format)
                case .timestamp: return try TextWorkbench.timestamp(source, unit: TimestampUnit(rawValue: index) ?? .automatic)
                case .compare: return try TextWorkbench.diff(source, other)
                case .basic: return requestedMode == .automatic ? source : try TextProcessor.process(source, operation: TextOperation.allCases[index])
                case .automatic: return source
                }
            } }.value
            guard !Task.isCancelled, let self, self.revision == token, ToolFeature.text.isEnabled(in: self.defaults) else { return }
            self.processing = false; self.output.isSelectable = true; self.output.textColor = .labelColor
            switch result {
            case .success(let text):
                self.output.string = text
                if selected == .compare { self.highlightDiff(text) }
                self.output.scrollRangeToVisible(NSRange(location: 0, length: 0))
                self.copyButton.isEnabled = !text.isEmpty
                self.setStatus(AppLanguage.english ? "Original: \(source.count) characters · Result: \(text.count)" : "原文 \(source.count) 字 · 结果 \(text.count) 字")
            case .failure(let error):
                self.output.string = ""; self.setStatus(error.localizedDescription)

            }
            self.task = nil
        }
    }
    private func highlightDiff(_ text: String) {
        guard let storage = output.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            if line.hasPrefix("+ ") || line.hasPrefix("- ") {
                storage.addAttribute(.foregroundColor, value: line.hasPrefix("+ ") ? NSColor.systemGreen : NSColor.systemRed, range: NSRange(location: offset, length: length))
            }
            offset += length + 1
        }
    }
    @objc private func copyResult() {
        guard ToolFeature.text.isEnabled(in: defaults), !processing, !output.string.isEmpty else { return }
        pasteboard.clearContents()
        let copied = pasteboard.setString(output.string, forType: .string)
        setStatus(copied ? (AppLanguage.english ? "Result copied." : "已复制处理结果。") : (AppLanguage.english ? "Copy failed." : "复制失败，请重试。"))
    }
    private func setStatus(_ value: String) { status.stringValue = value; status.toolTip = value }
    func windowWillClose(_ notification: Notification) { clearInput(); onClose?() }
    private static func title(_ operation: TextOperation) -> String {
        switch operation {
        case .trim: return AppLanguage.english ? "Trim Edges" : "去首尾空格"
        case .joinLines: return AppLanguage.english ? "Join Lines" : "合并换行"
        case .removeEmptyLines: return AppLanguage.english ? "Remove Blank Lines" : "去除空行"
        case .deduplicateLines: return AppLanguage.english ? "Deduplicate Lines" : "按行去重"
        case .uppercase: return AppLanguage.english ? "UPPERCASE" : "转为大写"
        case .lowercase: return AppLanguage.english ? "lowercase" : "转为小写"
        }
    }
}
