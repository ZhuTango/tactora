import AppKit

@MainActor
final class FileSearchSettingsView: NSView {
    private let index: FileSearchIndex
    private let directories = NSPopUpButton()
    private let info = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?
    init(index: FileSearchIndex = .shared) {
        self.index = index
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: AppLanguage.english ? "File Search" : "文件搜索")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: AppLanguage.english ? "Type a filename directly · ext:pdf filters files · type:folder finds folders. Local filename index; hidden files, packages and build caches are skipped. Remove all folders to stop indexing." : "直接输入文件名，ext:pdf 筛选类型，type:folder 搜文件夹。本地文件名索引，跳过隐藏内容、包内文件及构建缓存；移除全部目录即可停止索引。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        directories.setAccessibilityLabel(AppLanguage.english ? "Indexed folders" : "检索目录")
        directories.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let add = NSButton(title: AppLanguage.english ? "Add…" : "添加…", target: self, action: #selector(addFolder))
        let remove = NSButton(title: AppLanguage.english ? "Remove" : "移除", target: self, action: #selector(removeFolder))
        let rebuild = NSButton(title: AppLanguage.english ? "Rebuild Index" : "重建索引", target: self, action: #selector(rebuildIndex))
        let row = NSStackView(views: [directories, add, remove]); row.spacing = 8
        info.font = .systemFont(ofSize: 11); info.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, hint, row, rebuild, info])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor), info.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        observer = NotificationCenter.default.addObserver(forName: FileSearchIndex.changed, object: index, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    static func status(_ state: FileSearchIndex.State) -> String {
        if state.roots.isEmpty { return AppLanguage.english ? "No folders configured" : "尚未添加检索目录" }
        var text = state.scanning ? (AppLanguage.english ? "Indexing · \(state.count) items" : "索引中 · \(state.count) 项") : (AppLanguage.english ? "Indexed \(state.count) items" : "已索引 \(state.count) 项")
        if state.limited { text += AppLanguage.english ? " · 200k limit reached" : " · 已到 20 万项上限" }
        if !state.unavailable.isEmpty { text += AppLanguage.english ? " · Some folders unavailable" : " · 部分目录无权限或离线" }
        if !state.watching && !state.scanning { text += AppLanguage.english ? " · Live updates unavailable" : " · 实时监听不可用" }
        return text
    }
    private func refresh() {
        let selected = directories.titleOfSelectedItem
        let state = index.state
        directories.removeAllItems(); directories.addItems(withTitles: state.roots)
        if let selected { directories.selectItem(withTitle: selected) }
        info.stringValue = Self.status(state)
        info.toolTip = state.unavailable.joined(separator: "\n")
    }
    @objc private func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = AppLanguage.english ? "Add to Index" : "加入索引"
        guard panel.runModal() == .OK else { return }
        index.setRoots(index.state.roots + panel.urls.map(\.path)); refresh()
    }
    @objc private func removeFolder() {
        guard let selected = directories.titleOfSelectedItem else { return }
        index.setRoots(index.state.roots.filter { $0 != selected }); refresh()
    }
    @objc private func rebuildIndex() { index.rebuild() }
}
