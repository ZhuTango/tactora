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
    precondition(days.count == 49)
    for button in days {
     let rect = panel.convert(button.bounds,from:button)
     precondition(panel.bounds.contains(rect), "Date cell clipped")
     precondition(rect.width >= 27 && rect.height >= 27)
    }
    let today = views(panel).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "calendar.today" }!
    precondition(panel.bounds.contains(panel.convert(today.bounds,from:today)), "Today control clipped")
    func buttonRect(_ id: String) -> NSRect {
     let button = views(panel).first { $0.identifier?.rawValue == "calendar.\(id)" }!
     let rect = panel.convert(button.bounds, from: button)
     precondition(panel.bounds.contains(rect), "Header control clipped")
     return rect
    }
    let prevRect = buttonRect("previous"), todayRect = buttonRect("today")
    let nextRect = buttonRect("next"), settingsRect = buttonRect("settings")
    precondition(prevRect.maxX <= todayRect.minX && todayRect.maxX <= nextRect.minX)
    precondition(settingsRect.maxX <= prevRect.minX && abs(settingsRect.midY - todayRect.midY) <= 1, "\(nextRect) \(settingsRect) \(todayRect)")
    precondition(today.title.isEmpty && today.toolTip != nil)
    let bitmap = panel.bitmapImageRepForCachingDisplay(in:panel.bounds)!
    panel.cacheDisplay(in:panel.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:".build/calendar-\(weeks)-\(appearance.rawValue).png"))
   }
   let right = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!
   panel.keyDown(with:right)
   precondition(calendar.component(.year,from:panel.selectedDate) == 2027 && calendar.component(.day,from:panel.selectedDate) == 1)
   panel.moveMonth(-1)
   precondition(calendar.component(.month,from:panel.selectedDate) == 12)
   var resized: NSSize?
   panel.onSizeChange = { resized = $0 }
   panel.moveMonth(2) // February 2027 requires four month rows plus two context rows.
   precondition(resized?.height == 332 && panel.frame.height == 332)
   precondition(views(panel).filter { $0.identifier?.rawValue.hasPrefix("calendar.day.") == true }.count == 42)
   panel.moveMonth(1)
   precondition(resized?.height == 364 && panel.frame.height == 364)
   let choose = views(panel).first { $0.identifier?.rawValue == "calendar.chooseMonth" } as! NSButton
   choose.performClick(nil)
   panel.layoutSubtreeIfNeeded()
   precondition(panel.frame.height == 402)
   let picker = views(panel).first { $0.identifier?.rawValue == "calendar.monthPicker" } as! NSDatePicker
   precondition(panel.bounds.contains(panel.convert(picker.bounds, from: picker)))
   let preview = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
   panel.cacheDisplay(in: panel.bounds, to: preview)
   try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/calendar-month-picker.png"))
   picker.dateValue = calendar.date(from: DateComponents(year: 2032, month: 2, day: 1))!
   let jump = views(panel).first { $0.identifier?.rawValue == "calendar.jump" } as! NSButton
   jump.performClick(nil)
   precondition(calendar.component(.year, from: panel.selectedDate) == 2032)
   precondition(calendar.component(.month, from: panel.selectedDate) == 2)
   precondition(picker.superview!.isHidden)
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
