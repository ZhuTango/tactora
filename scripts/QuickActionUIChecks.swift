import AppKit
import CoreImage
@main struct Checks {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let suite = "quick-actions.ui." + UUID().uuidString
  let defaults = UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  let app = SwitcherApp(id:"test.wechat",name:"WeChat",path:"/Applications/WeChat.app")
  precondition(QuickActionsWindow.appTitle(app,alias:"微信") == "微信（WeChat）")
  precondition(QuickActionsWindow.appTitle(app,alias:" wechat ") == "WeChat")
  let currencyData = Data("{\"date\":\"2026-11-18\",\"base\":\"EUR\",\"rates\":{\"USD\":1.2,\"CNY\":8.4}}".utf8)
  let rates = CurrencyRates(defaults: defaults, fetch: { currencyData })
  let emptyIndex = FileSearchIndex(defaults: defaults, cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json"), roots: [], watch: false)
  defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")) }
  let panel = QuickActionsWindow(defaults:defaults, currencyRates: rates)
  panel.fileIndexProvider = { emptyIndex }
  panel.commandProvider = { [QuickAction(id:"maximize",title:"最大化",keywords:"maximize",destination:.command("maximize"))] }
  panel.present()
  panel.search.stringValue = "zdh"; panel.rebuild()
  precondition(panel.results.first?.id == "maximize")
  panel.commandProvider = { [QuickAction(id:"maximize",title:"最大化",destination:.command("maximize")),QuickAction(id:"other",title:"其他",destination:.command("other"))] }
  panel.dismiss(restoreFocus:false); panel.present()
  panel.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
  let selected = panel.results[panel.table.selectedRow].id
  panel.rebuild(preservingSelection:true)
  precondition(panel.results[panel.table.selectedRow].id == selected, "Background refresh preserves selection")
  panel.search.stringValue = "{\"a\":1}"; panel.rebuild()
  guard case .text(let content) = panel.results.first?.destination else { fatalError("Missing JSON route") }
  precondition(content == "{\"a\":1}")
  panel.search.stringValue = "1700000000000"; panel.rebuild()
  precondition(panel.results.first?.id == "content.text")
  precondition(panel.results.contains { $0.id == "content.currencyHint" }, "Timestamp input also offers currency without displacing timestamp")
  panel.search.stringValue = "100"; panel.rebuild()
  precondition(Set(["content.currencyHint", "content.mathHint", "content.unitHint"]).isSubset(of: Set(panel.results.map(\.id))))
  let hintIndex = panel.results.firstIndex { $0.id == "content.currencyHint" }!
  panel.table.selectRowIndexes(IndexSet(integer: hintIndex), byExtendingSelection: false)
  panel.executeSelected()
  precondition(panel.search.stringValue == CurrencyQuery.completion(amount: "100", english: AppLanguage.english).text && panel.window!.isVisible)
  try await Task.sleep(nanoseconds: 400_000_000)
  precondition(panel.results.first?.id == "content.currency")
  precondition(QuickActionHistory(defaults: defaults).recent.isEmpty)
  panel.search.stringValue = "100美元兑人民币"; panel.rebuild()
  try await Task.sleep(nanoseconds: 400_000_000)
  guard case .calculation(let converted) = panel.results.first?.destination else { fatalError("Missing currency result") }
  precondition(converted == "700.00" && panel.results.first?.id == "content.currency")
  panel.search.stringValue = "200 USD CNY"; panel.rebuild()
  precondition(!panel.results.contains { $0.id == "content.currency" }, "Old amount is removed immediately")
  panel.search.stringValue = "zdh"; panel.rebuild()
  try await Task.sleep(nanoseconds: 400_000_000)
  precondition(panel.results.first?.id == "maximize", "Canceled request must not overwrite app search")
  panel.search.stringValue = "100 USD CNY"; panel.rebuild()
  panel.dismiss(restoreFocus: false); panel.present()
  try await Task.sleep(nanoseconds: 400_000_000)
  precondition(!panel.results.contains { $0.id == "content.currency" }, "Closed session must not receive stale rates")
  precondition(QuickInputActions.unitResult("256 MiB 转 MB") == "268.435456 MB")
  precondition(QuickInputActions.unitResult("100 cm → m") == "1 m")
  precondition(QuickInputActions.unitResult("100 厘米转米") == "1 m")
  precondition(QuickInputActions.unitResult("32华氏度转摄氏度") == "0 °C")
  precondition(QuickInputActions.unitResult("12 kg to km") == nil)
  precondition(QuickInputActions.date("2025-02-29") == nil)
  panel.search.stringValue = "2026年11月19日"; panel.rebuild()
  precondition(panel.results.prefix(2).map(\.id) == ["content.date", "content.note"])
  precondition(panel.results.first?.title.contains("Thursday") == true || panel.results.first?.title.contains("星期四") == true)
  let url = URL(string: "https://example.com/a?q=42")!
  panel.search.stringValue = url.absoluteString; panel.rebuild()
  precondition(panel.results.prefix(2).map(\.id) == ["content.url", "content.qr"])
  let qr = QuickInputActions.qrImage(url)!
  let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)!
  let decoded = detector.features(in: CIImage(data: qr.tiffRepresentation!)!).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
  precondition(decoded.contains(url.absoluteString))
  panel.window!.makeFirstResponder(panel.search)
  let pasteBoard = NSPasteboard.withUniqueName()
  defer { pasteBoard.releaseGlobally() }
  let pasted = "项目复盘\n第二行"
  pasteBoard.setString(pasted, forType: .string)
  let pasteEditor = panel.search.currentEditor() as! NSTextView
  pasteEditor.selectAll(nil)
  precondition(pasteEditor.readSelection(from: pasteBoard, type: .string))
  precondition(panel.results.contains { if case .clipboardSearch = $0.destination { return true }; return false })
  precondition(panel.results.contains { if case .text(let value) = $0.destination { return value == pasted }; return false })
  panel.search.stringValue = "12*(3+4)"; panel.rebuild()
  guard case .calculation(let result) = panel.results.first?.destination else { fatalError("Missing calculator") }
  precondition(result == "84" && panel.table.selectedRow == 0)
  var copied: String?
  panel.onExecute = { action, _, completion in
   guard case .calculation(let value) = action.destination else { fatalError("Wrong action") }
   copied = value; completion(.success(()))
  }
  panel.executeSelected()
  precondition(copied == "84" && !panel.window!.isVisible)
  precondition(QuickActionHistory(defaults:defaults).recent.isEmpty, "Calculations do not pollute command history")
  panel.present()
  panel.search.stringValue = "1/0"; panel.rebuild()
  precondition(panel.results.isEmpty, "Invalid calculation cannot be executed")
  panel.search.stringValue = "1+"; panel.rebuild()
  precondition(panel.results.isEmpty)
  precondition(QuickActionsWindow.awakeMinutes("防休眠 30") == 30)
  precondition(QuickActionsWindow.awakeMinutes("awake 5 min") == 5)
  precondition(QuickActionsWindow.awakeMinutes("防休眠 0") == nil)
  precondition(QuickActionsWindow.awakeMinutes("防休眠 99999") == nil)
  panel.search.stringValue = "zdh"; panel.rebuild()
  var calls = 0
  panel.onExecute = { _, _, completion in
   calls += 1
   completion(.failure(NSError(domain:"test",code:1,userInfo:[NSLocalizedDescriptionKey:"Window closed"])))
  }
  let editor = panel.window!.fieldEditor(true, for:panel.search) as! NSTextView
  panel.window!.makeFirstResponder(editor)
  editor.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
  precondition(panel.isComposing)
  panel.executeSelected(); precondition(calls == 0, "IME candidate confirmation must not run an action")
  editor.unmarkText()
  panel.search.stringValue = "zdh"; panel.rebuild()
  panel.executeSelected()
  precondition(calls == 1 && panel.window!.isVisible && panel.search.stringValue == "zdh", "Failure keeps panel and query")
  for appearance in [NSAppearance.Name.aqua,.darkAqua] {
   panel.window!.appearance = NSAppearance(named:appearance)
   let view = panel.window!.contentView!
   view.layoutSubtreeIfNeeded()
   precondition(view.bounds.contains(panel.search.frame))
   let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
   view.cacheDisplay(in:view.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/quick-actions-\(appearance.rawValue).png"))
  }
  panel.onExecute = { _,_,completion in completion(.success(())) }
  panel.executeSelected(); precondition(!panel.window!.isVisible)
  precondition(QuickActionHistory(defaults:defaults).recent == ["maximize"])
  panel.present(); panel.dismiss(restoreFocus:true)
  precondition(panel.context == nil && panel.search.stringValue.isEmpty)
  panel.close()
  panel.commandProvider = { (0..<12).map { QuickAction(id:"item.\($0)",title:["搜索剪贴板历史", "最大化", "截图识字", "文本处理"][$0 % 4],symbol:["doc.on.clipboard", "macwindow", "text.viewfinder", "text.alignleft"][$0 % 4],destination:.command("item")) } }
  panel.present()
  precondition(panel.results.count == 4, "Initial view limits suggestions")
  for appearance in [NSAppearance.Name.aqua,.darkAqua] {
   panel.window!.appearance = NSAppearance(named:appearance)
   let view = panel.window!.contentView!
   view.layoutSubtreeIfNeeded()
   let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
   view.cacheDisplay(in:view.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/quick-actions-home-\(appearance.rawValue).png"))
  }
  panel.search.stringValue = "最大化"; panel.rebuild()
  precondition(panel.results.count == 3, "Search still finds actions outside initial suggestions")
  panel.close()
  panel.commandProvider = { [
   QuickAction(id:"app.finder",title:"访达（Finder）",detail:"打开应用",destination:.application("/System/Library/CoreServices/Finder.app")),
   QuickAction(id:"clipboard",title:"搜索剪贴板历史",symbol:"doc.on.clipboard",destination:.command("clipboard")),
   QuickAction(id:"ocr",title:"截图识字",symbol:"text.viewfinder",destination:.command("ocr")),
   QuickAction(id:"fans",title:"风扇温控设置",symbol:"fan",destination:.command("fans"))
  ] }
  panel.present()
  panel.search.stringValue = "fd"; panel.rebuild()
  for appearance in [NSAppearance.Name.aqua,.darkAqua] {
   panel.window!.appearance = NSAppearance(named:appearance)
   let view = panel.window!.contentView!
   view.layoutSubtreeIfNeeded()
   let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
   view.cacheDisplay(in:view.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/quick-actions-icons-\(appearance.rawValue).png"))
  }
  panel.close()
  let aliasPanel = QuickActionsWindow(defaults:defaults)
  aliasPanel.fileIndexProvider = { emptyIndex }
  var alias = "微信"
  aliasPanel.configuredApps = { [SwitcherApp(id:"alias.fixture",name:"WeChat",path:"/System/Library/CoreServices/Finder.app")] }
  aliasPanel.appAlias = { _ in alias }
  aliasPanel.present()
  aliasPanel.search.stringValue = "weixin"; aliasPanel.rebuild()
  precondition(aliasPanel.results.first?.title == "微信（WeChat）")
  precondition(aliasPanel.results.contains { if case .locateWindow = $0.destination { return true }; return false })
  aliasPanel.dismiss(restoreFocus:false)
  alias = "聊天"
  aliasPanel.present()
  aliasPanel.search.stringValue = "liaotian"; aliasPanel.rebuild()
  precondition(aliasPanel.results.first?.title == "聊天（WeChat）", "Alias refresh must bypass inventory cache")
  aliasPanel.search.stringValue = "weixin"; aliasPanel.rebuild()
  precondition(aliasPanel.results.isEmpty, "Old alias is removed from search")
  aliasPanel.close()
  let fileRoot = FileManager.default.temporaryDirectory.appendingPathComponent("file-ui-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: fileRoot) }
  let file = fileRoot.appendingPathComponent("合同.txt")
  try Data("file search fixture".utf8).write(to: file)
  let fileIndex = FileSearchIndex(defaults: defaults, cacheURL: fileRoot.appendingPathComponent(".index.json"), roots: [fileRoot.path], watch: false)
  let filePanel = QuickActionsWindow(defaults: defaults)
  filePanel.fileIndexProvider = { fileIndex }
  filePanel.present()
  filePanel.search.stringValue = "合同 ext:txt"; filePanel.rebuild()
  for _ in 0..<30 {
   if filePanel.results.count == 1 { break }
   try await Task.sleep(nanoseconds: 100_000_000)
  }
  guard case .file(let found) = filePanel.results.first?.destination else { fatalError("Missing file search result") }
  precondition(found.hasSuffix("/合同.txt"))
  func resultTitle(_ view: NSView) -> NSTextField? {
   if let field = view as? NSTextField, field.stringValue == "合同.txt" { return field }
   return view.subviews.lazy.compactMap(resultTitle).first
  }
  for input in ["hetong ext:txt", "/ht EXT:txt"] {
   filePanel.search.stringValue = input; filePanel.rebuild()
   try await Task.sleep(nanoseconds: 350_000_000)
   precondition(filePanel.results.first?.title == "合同.txt")
   let row = filePanel.tableView(filePanel.table, viewFor: filePanel.table.tableColumns.first, row: 0)!
   let text = resultTitle(row)!.attributedStringValue
   for i in 0..<text.length {
    precondition(((text.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor) == QuickActionRowView.matchColor) == (i < 2))
   }
  }
  try Data("second fixture".utf8).write(to: fileRoot.appendingPathComponent(String(repeating: "项目合同管理", count: 10) + ".txt"))
  fileIndex.rebuild()
  for _ in 0..<30 {
   if filePanel.results.count == 2 { break }
   try await Task.sleep(nanoseconds: 100_000_000)
  }
  precondition(filePanel.results.count == 2, "Index notifications refresh visible results")
  precondition(filePanel.results[filePanel.table.selectedRow].title == "合同.txt", "Refresh preserves selected file")
  filePanel.commandProvider = { [QuickAction(id: "contract.command", title: "合同操作", destination: .command("contract"))] }
  filePanel.dismiss(restoreFocus: false); filePanel.present()
  filePanel.search.stringValue = "合同"; filePanel.rebuild()
  precondition(filePanel.results.first?.id == "contract.command", "Existing actions remain immediately available")
  try await Task.sleep(nanoseconds: 300_000_000)
  precondition(filePanel.results.count == 3 && filePanel.results.first?.id == "contract.command")
  precondition(filePanel.results[filePanel.table.selectedRow].id == "contract.command", "Incoming files must not change selected action")
  filePanel.search.stringValue = "/合同"; filePanel.rebuild()
  try await Task.sleep(nanoseconds: 300_000_000)
  precondition(filePanel.results.count == 2 && filePanel.results.allSatisfy { $0.id.hasPrefix("file:") }, "Slash remains optional files-only filter")
  let priorHistory = QuickActionHistory(defaults: defaults).recent
  var fileAction = false
  filePanel.onExecute = { action, _, completion in
   if case .file = action.destination { fileAction = true }
   completion(.success(()))
  }
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
   filePanel.window!.appearance = NSAppearance(named: appearance)
   let view = filePanel.window!.contentView!; view.layoutSubtreeIfNeeded()
   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
   view.cacheDisplay(in: view.bounds, to: bitmap)
   try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/file-search-\(appearance.rawValue).png"))
  }
  filePanel.executeSelected()
  precondition(fileAction && !filePanel.window!.isVisible)
  precondition(QuickActionHistory(defaults: defaults).recent == priorHistory)
  filePanel.present(); filePanel.search.stringValue = "/合同"; filePanel.rebuild()
  filePanel.search.stringValue = "12*7"; filePanel.rebuild()
  try await Task.sleep(nanoseconds: 300_000_000)
  precondition(filePanel.results.first?.id == "content.calculation", "Old file query cannot overwrite calculation")
  filePanel.dismiss(restoreFocus: false)
  let pdfURL = fileRoot.appendingPathComponent("preview-check.pdf")
  let page = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
  try page.dataWithPDF(inside: page.bounds).write(to: pdfURL)
  fileIndex.rebuild()
  filePanel.present(); filePanel.search.stringValue = "/preview-check"; filePanel.rebuild()
  for _ in 0..<30 where filePanel.results.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
  fileAction = false
  filePanel.executeSelected()
  precondition(!fileAction && NSApp.windows.contains { $0.title == pdfURL.lastPathComponent && $0.isVisible })
  filePanel.dismiss(restoreFocus: false)
  let png = fileRoot.appendingPathComponent("space-probe.png")
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  try bitmap.representation(using: .png, properties: [:])!.write(to: png)
  fileIndex.rebuild()
  filePanel.present(); filePanel.search.stringValue = "space-probe"; filePanel.rebuild()
  for _ in 0..<40 where filePanel.results.first?.title != png.lastPathComponent { try await Task.sleep(nanoseconds: 100_000_000) }
  let searchWindow = filePanel.window!
  searchWindow.makeFirstResponder(filePanel.search)
  let fileEditor = filePanel.search.currentEditor() as! NSTextView
  fileEditor.setSelectedRange(NSRange(location: filePanel.search.stringValue.utf16.count, length: 0))
  func sendSpace(_ flags: NSEvent.ModifierFlags = []) {
   NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: searchWindow.windowNumber,
    context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
  }
  sendSpace()
  precondition(NSApp.windows.contains { $0.title == png.lastPathComponent && $0.isVisible })
  precondition(filePanel.search.stringValue == "space-probe")
  sendSpace()
  precondition(!NSApp.windows.contains { $0.title == png.lastPathComponent && $0.isVisible })
  sendSpace(.shift)
  precondition(filePanel.search.stringValue == "space-probe ")
  filePanel.dismiss(restoreFocus: false)
  filePanel.present()
  let english = AppLanguage.english
  func elements(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(elements) }
  let controls = elements(filePanel.window!.contentView!)
  let scopeButton = controls.compactMap { $0 as? NSButton }.first { $0.title == (english ? "Search scope…" : "查看检索范围…") }!
  filePanel.search.stringValue = "/missing-fixture"; filePanel.rebuild()
  try await Task.sleep(nanoseconds: 500_000_000)
  precondition(filePanel.results.isEmpty && !scopeButton.isHidden)
  for i in 0..<81 { try Data().write(to: fileRoot.appendingPathComponent("limit-fixture-\(i).txt")) }
  fileIndex.rebuild()
  filePanel.search.stringValue = "/limit-fixture"; filePanel.rebuild()
  for _ in 0..<30 where filePanel.results.count != 80 { try await Task.sleep(nanoseconds: 100_000_000) }
  let fields = controls.compactMap { $0 as? NSTextField }
  precondition(filePanel.results.count == 80 && scopeButton.isHidden)
  precondition(fields.contains { $0.stringValue.contains(english ? "Top 80" : "前 80") })
  filePanel.dismiss(restoreFocus: false)
  let fileSettings = FileSearchSettingsView(index: fileIndex)
  fileSettings.frame = NSRect(x: 0, y: 0, width: 560, height: 230)
  fileSettings.layoutSubtreeIfNeeded()
  let shortcut = QuickActionsShortcut(defaults:defaults)
  shortcut.conflicts = { _ in true }
  precondition(!shortcut.setShortcut(QuickActionsShortcut.defaultShortcut))
  precondition(shortcut.shortcut == QuickActionsShortcut.defaultShortcut)
  precondition(shortcut.setShortcut(nil) && shortcut.shortcut == nil)
  precondition(QuickActionsShortcut(defaults:defaults).shortcut == nil)
  print("PASS: search, JSON/timestamp handoff, duration bounds, IME guard, failed action retention, success recents, close cleanup, shortcut conflict and clearing")
 }
}
