import Foundation
@main struct Checks {
 static func main() {
  let name = "quick-actions.test." + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let aliasAction = QuickAction(id:"wechat",title:"微信（WeChat）",destination:.application("/Applications/WeChat.app"))
  for query in ["微信", "wechat", "weixin", "wx", "wei xin"] {
   precondition(aliasAction.matchRank(query) != nil, "Alias and pinyin search: \(query)")
   precondition(!aliasAction.highlightRanges(query).isEmpty, "Highlight: \(query)")
  }
  precondition(aliasAction.highlightRanges("wx") == [NSRange(location:0,length:1), NSRange(location:1,length:1)])
  precondition(aliasAction.highlightRanges("wechat").count == 6)
  precondition(aliasAction.highlightRanges("").isEmpty)
  let unicode = QuickAction(id:"unicode",title:"😀微信 Café",destination:.command("test"))
  precondition(unicode.highlightRanges("wx").first?.location == 2)
  precondition(unicode.highlightRanges("cafe").count == 4)
  let history = QuickActionHistory(defaults: defaults)
  let actions = [
   QuickAction(id:"window",title:"最大化",keywords:"maximize 放大",destination:.command("window")),
   QuickAction(id:"fans",title:"风扇温控",keywords:"fan temperature",destination:.command("fans")),
   QuickAction(id:"fansSettings",title:"设置",keywords:"风扇",destination:.command("settings"))
  ]
  precondition(history.results(actions,query:"zdh").first?.id == "window")
  precondition(history.results(actions,query:"wendu").isEmpty)
  history.toggleFavorite("fansSettings")
  precondition(history.results(actions,query:"风扇温控").first?.id == "fans")
  precondition(history.results(actions,query:"风扇").first?.id == "fans")
  precondition(history.results(actions,query:"").first?.id == "fansSettings")
  history.record("window"); history.record("fans"); history.record("window")
  precondition(history.recent == ["window","fans"])
  let restored = QuickActionHistory(defaults:defaults)
  precondition(restored.favorites == ["fansSettings"] && restored.recent == history.recent)
  print("PASS: exact/prefix/pinyin ranking, favorite tie-breaks, recent deduplication and persistence")
 }
}
