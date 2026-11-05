import Foundation
@main struct Checks {
 static func main() {
  let name = "quick-actions.test." + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
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
