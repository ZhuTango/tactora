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
   precondition(views(panel).contains { $0.identifier?.rawValue == "calendar.notes.open" }, "Date notes entry missing")
   let right = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!
   panel.keyDown(with:right)
   precondition(calendar.component(.year,from:panel.selectedDate) == 2027 && calendar.component(.day,from:panel.selectedDate) == 1)
   panel.moveMonth(-1)
   precondition(calendar.component(.month,from:panel.selectedDate) == 1, "Browsing months must preserve the selected date")
   var resized: NSSize?
   panel.onSizeChange = { resized = $0 }
   panel.moveMonth(2) // February 2027 requires four month rows plus two context rows.
   precondition(resized?.height == 416 && panel.frame.height == 416)
   precondition(views(panel).filter { $0.identifier?.rawValue.hasPrefix("calendar.day.") == true }.count == 42)
   panel.moveMonth(1)
   precondition(resized?.height == 462 && panel.frame.height == 462)
   let choose = views(panel).first { $0.identifier?.rawValue == "calendar.chooseMonth" } as! NSButton
   choose.performClick(nil)
   panel.layoutSubtreeIfNeeded()
   precondition(panel.frame.height == 462)
   precondition(views(panel).filter { $0.identifier?.rawValue.hasPrefix("calendar.day.") == true }.isEmpty)
   panel.moveMonth(1)
   let year = views(panel).first { $0.identifier?.rawValue == "calendar.year.2032" } as! NSButton
   year.performClick(nil)
   panel.layoutSubtreeIfNeeded()
   precondition(panel.frame.height == 462)
   let months = views(panel).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("calendar.month.") == true }
   precondition(months.count == 12)
   for button in months { precondition(panel.bounds.contains(panel.convert(button.bounds, from: button))) }
   let preview = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
   panel.cacheDisplay(in: panel.bounds, to: preview)
   try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/calendar-month-picker.png"))
   months.first { $0.tag == 2 }!.performClick(nil)
   precondition(calendar.component(.year, from: panel.month) == 2032)
   precondition(calendar.component(.month, from: panel.month) == 2)
   precondition(calendar.component(.year,from:panel.selectedDate) == 2027 && calendar.component(.day,from:panel.selectedDate) == 1)
   precondition(views(panel).filter { $0.identifier?.rawValue.hasPrefix("calendar.month.") == true }.isEmpty)
   window.orderOut(nil)
  }
  let notesStore = CalendarNotesStore()
  let notePanel = CalendarPanel(firstWeekday:2, showWeeks:false, date:date, notesStore:notesStore)
  let noteWindow = NSWindow(contentRect:notePanel.frame,styleMask:[.titled],backing:.buffered,defer:false)
  noteWindow.contentView = notePanel
  func noteButton(_ id: String) -> NSButton { views(notePanel).first { $0.identifier?.rawValue == id } as! NSButton }
  noteButton("calendar.notes.open").performClick(nil)
  precondition(notePanel.frame.width == 610)
  let input = views(notePanel).first { $0.identifier?.rawValue == "calendar.notes.input" } as! NSTextField
  let day = CalendarNotesStore.dayKey(date,calendar:calendar)
  input.stringValue = "买猫粮，顺路取快递"
  noteButton("calendar.notes.add").performClick(nil)
  precondition(notesStore.entries(on:day).count == 1 && input.stringValue.isEmpty)
  let item = notesStore.entries(on:day)[0]
  noteButton("calendar.note.toggle.\(item.id)").performClick(nil)
  precondition(notesStore.entries(on:day)[0].completed)
  input.stringValue = "尚未提交的新事项"
  notesViewDraftCheck: do {
   let detailView = views(notePanel).first { $0.identifier?.rawValue == "calendar.notes" } as! CalendarNotesView
   detailView.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:input))
   noteButton("calendar.note.edit.\(item.id)").performClick(nil)
   precondition(input.stringValue == "尚未提交的新事项", "Edit must not overwrite a new draft")
   input.stringValue = ""
   detailView.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:input))
  }
  noteButton("calendar.note.edit.\(item.id)").performClick(nil)
  input.stringValue = "买猫粮和猫砂"
  noteButton("calendar.notes.add").performClick(nil)
  precondition(notesStore.entries(on:day)[0].text == "买猫粮和猫砂")
  precondition(notesStore.entries(on:day)[0].completed)
  // Chinese IME confirmation must not submit unfinished text.
  let notesView = views(notePanel).first { $0.identifier?.rawValue == "calendar.notes" } as! CalendarNotesView
  let ime = NSTextView()
  ime.setMarkedText("待确认", selectedRange:NSRange(location:0,length:3), replacementRange:NSRange(location:NSNotFound,length:0))
  precondition(!notesView.control(input,textView:ime,doCommandBy:#selector(NSResponder.insertNewline(_:))))
  precondition(notesStore.entries(on:day).count == 1)
  input.stringValue = "还没输入完"
  notesView.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:input))
  let model = CalendarMonth(containing:date)
  let another = model.days.firstIndex { calendar.component(.day,from:$0) == 30 && model.contains($0) }!
  noteButton("calendar.day.\(another)").performClick(nil)
  precondition(input.stringValue.isEmpty)
  let original = model.days.firstIndex { calendar.isDate($0,inSameDayAs:date) }!
  noteButton("calendar.day.\(original)").performClick(nil)
  precondition(input.stringValue == "还没输入完")
  for i in 1...15 { try notesStore.add("待办 \(i)：检查长文本在右侧自动换行，保持日期网格不变。",on:day) }
  notePanel.reload(); notePanel.layoutSubtreeIfNeeded()
  for appearance in [NSAppearance.Name.aqua,.darkAqua] {
   noteWindow.appearance = NSAppearance(named:appearance)
   notePanel.layoutSubtreeIfNeeded(); notePanel.displayIfNeeded()
   let rect = notePanel.convert(input.bounds,from:input)
   precondition(notePanel.bounds.contains(rect) && rect.width > 150)
   let bitmap = notePanel.bitmapImageRepForCachingDisplay(in:notePanel.bounds)!
   notePanel.cacheDisplay(in:notePanel.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/calendar-notes-\(appearance.rawValue).png"))
  }
  noteButton("calendar.note.delete.\(item.id)").performClick(nil)
  precondition(!notesStore.entries(on:day).contains { $0.id == item.id })
  noteButton("calendar.notes.close").performClick(nil)
  precondition(notePanel.frame.width == 310)
  noteWindow.orderOut(nil)
  let tool = CalendarTool(defaults:defaults)
  precondition(!tool.showHolidays)
  let settings = CalendarSettingsView(manager:tool)
  let holidayToggle = views(settings).first { $0.identifier?.rawValue == "calendar.showHolidays" } as! NSButton
  holidayToggle.performClick(nil)
  precondition(CalendarTool(defaults:defaults).showHolidays)
  holidayToggle.performClick(nil)
  precondition(!CalendarTool(defaults:defaults).showHolidays)
  let holidayDate = calendar.date(from:DateComponents(year:2026,month:5,day:1,hour:12))!
  for enabled in [false,true] {
   let panel = CalendarPanel(firstWeekday:2,showWeeks:true,showHolidays:enabled,date:holidayDate)
   let window = NSWindow(contentRect:panel.frame,styleMask:[.titled],backing:.buffered,defer:false)
   window.contentView = panel
   panel.layoutSubtreeIfNeeded()
   let entries = views(panel).compactMap { $0 as? NSButton }.filter { $0.toolTip?.contains("劳动节 · 放假") == true }
   precondition(entries.count == (enabled ? 5 : 0))
   if enabled {
    precondition(views(panel).compactMap { $0 as? NSButton }.contains { $0.toolTip?.contains("劳动节 · 调休上班") == true })
    let bitmap = panel.bitmapImageRepForCachingDisplay(in:panel.bounds)!
    panel.cacheDisplay(in:panel.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:".build/calendar-holidays.png"))
   }
   window.orderOut(nil)
  }
  tool.refresh(); precondition(tool.statusItem != nil)
  ToolFeature.calendar.setEnabled(false,in:defaults); tool.refresh(); precondition(tool.statusItem == nil)
  defaults.set(1,forKey:"calendar.firstWeekday"); defaults.set(true,forKey:"calendar.showWeeks")
  let restored = CalendarTool(defaults:defaults)
  precondition(restored.firstWeekday == 1 && restored.showWeeks)
  tool.stop(); restored.stop()
  print("PASS: calendar layout in light/dark, week columns, keyboard year navigation, enable/disable, preference restoration")
 }
}
