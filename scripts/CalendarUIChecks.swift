import AppKit
@main struct CalendarUIChecks {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let suite = "tactora.calendar.test.\(UUID())", defaults = UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  var calendar = Calendar(identifier:.gregorian); calendar.timeZone = .current
  let date = calendar.date(from:DateComponents(year:2026,month:12,day:31,hour:12))!
  func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
  for weeks in [false,true] {
   let panel = CalendarPanel(firstWeekday:2,showWeeks:weeks,date:date)
   let window = NSWindow(contentRect:panel.frame,styleMask:[.titled],backing:.buffered,defer:false)
   window.contentView = panel
   for appearance in [NSAppearance.Name.aqua,.darkAqua] {
    window.appearance = NSAppearance(named:appearance)
    panel.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
    let days = views(panel).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("calendar.day.") == true }
    precondition(days.count == 42)
    for button in days {
     let rect = panel.convert(button.bounds,from:button)
     precondition(panel.bounds.contains(rect), "Date cell clipped")
     precondition(rect.width >= 27 && rect.height >= 27)
    }
    let today = views(panel).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "calendar.today" }!
    precondition(panel.bounds.contains(panel.convert(today.bounds,from:today)), "Footer clipped")
    let bitmap = panel.bitmapImageRepForCachingDisplay(in:panel.bounds)!
    panel.cacheDisplay(in:panel.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:".build/calendar-\(weeks)-\(appearance.rawValue).png"))
   }
   let right = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!
   panel.keyDown(with:right)
   precondition(calendar.component(.year,from:panel.selectedDate) == 2027 && calendar.component(.day,from:panel.selectedDate) == 1)
   panel.moveMonth(-1)
   precondition(calendar.component(.month,from:panel.selectedDate) == 12)
   window.orderOut(nil)
  }
  let tool = CalendarTool(defaults:defaults)
  tool.refresh(); precondition(tool.statusItem != nil)
  ToolFeature.calendar.setEnabled(false,in:defaults); tool.refresh(); precondition(tool.statusItem == nil)
  defaults.set(1,forKey:"calendar.firstWeekday"); defaults.set(true,forKey:"calendar.showWeeks")
  let restored = CalendarTool(defaults:defaults)
  precondition(restored.firstWeekday == 1 && restored.showWeeks)
  tool.stop(); restored.stop()
  print("PASS: calendar layout in light/dark, week columns, keyboard year navigation, enable/disable, preference restoration")
 }
}
