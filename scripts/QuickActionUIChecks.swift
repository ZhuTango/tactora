import AppKit
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
  let panel = QuickActionsWindow(defaults:defaults, currencyRates: rates)
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
  var alias = "微信"
  aliasPanel.configuredApps = { [SwitcherApp(id:"alias.fixture",name:"WeChat",path:"/System/Library/CoreServices/Finder.app")] }
  aliasPanel.appAlias = { _ in alias }
  aliasPanel.present()
  aliasPanel.search.stringValue = "weixin"; aliasPanel.rebuild()
  precondition(aliasPanel.results.first?.title == "微信（WeChat）")
  aliasPanel.dismiss(restoreFocus:false)
  alias = "聊天"
  aliasPanel.present()
  aliasPanel.search.stringValue = "liaotian"; aliasPanel.rebuild()
  precondition(aliasPanel.results.first?.title == "聊天（WeChat）", "Alias refresh must bypass inventory cache")
  aliasPanel.search.stringValue = "weixin"; aliasPanel.rebuild()
  precondition(aliasPanel.results.isEmpty, "Old alias is removed from search")
  aliasPanel.close()
  let shortcut = QuickActionsShortcut(defaults:defaults)
  shortcut.conflicts = { _ in true }
  precondition(!shortcut.setShortcut(QuickActionsShortcut.defaultShortcut))
  precondition(shortcut.shortcut == QuickActionsShortcut.defaultShortcut)
  precondition(shortcut.setShortcut(nil) && shortcut.shortcut == nil)
  precondition(QuickActionsShortcut(defaults:defaults).shortcut == nil)
  print("PASS: search, JSON/timestamp handoff, duration bounds, IME guard, failed action retention, success recents, close cleanup, shortcut conflict and clearing")
 }
}
