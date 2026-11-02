import Foundation
@main struct CalendarNotesChecks {
 @MainActor static func main() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-notes-\(UUID())")
  defer { try? FileManager.default.removeItem(at:folder) }
  let url = folder.appendingPathComponent("notes.json")
  let store = CalendarNotesStore(fileURL:url)
  let day = "2026-11-02", next = "2026-11-03"
  try store.add("  买猫粮  ", on:day)
  try store.add("安排会议", on:next)
  try store.add(" \n ", on:day)
  precondition(store.entries(on:day).count == 1)
  let item = store.entries(on:day)[0]
  precondition(item.text == "买猫粮" && !item.completed)
  try store.update(item.id, text:"买猫粮和猫砂", completed:true, on:day)
  let restored = CalendarNotesStore(fileURL:url)
  precondition(restored.entries(on:day)[0].completed)
  precondition(restored.entries(on:day)[0].text == "买猫粮和猫砂")
  precondition(restored.entries(on:next)[0].text == "安排会议")
  try restored.remove(item.id,on:day)
  precondition(CalendarNotesStore(fileURL:url).entries(on:day).isEmpty)
  let corrupted = Data("broken".utf8)
  try corrupted.write(to:url)
  let broken = CalendarNotesStore(fileURL:url)
  precondition(broken.loadError != nil)
  do { try broken.add("不覆盖",on:day); preconditionFailure("Corrupt file must be preserved") } catch {}
  let preserved = try Data(contentsOf:url)
  precondition(preserved == corrupted)
  let blocked = CalendarNotesStore(fileURL:folder) // An existing directory cannot be overwritten.
  do { try blocked.add("失败不能假装保存",on:day); preconditionFailure() } catch {}
  precondition(blocked.entries(on:day).isEmpty)
  var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"Asia/Shanghai")!
  let date = calendar.date(from:DateComponents(year:2026,month:11,day:2,hour:23))!
  precondition(CalendarNotesStore.dayKey(date,calendar:calendar) == day)
  print("PASS: calendar notes create/edit/complete/delete, date isolation, restart persistence, corrupt-file protection")
 }
}
