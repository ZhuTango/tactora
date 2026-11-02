import AppKit
@main struct CalendarUIChecks {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let suite = "tactora.calendar.test.\(UUID())", defaults = UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  var calendar = Calendar(identifier:.gregorian); calendar.timeZone = .current
  let date = calendar.date(from:DateComponents(year:2026,month:12,day:31,hour:12))!
  func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) + ((root is CalendarPanel) ? (root.window?.childWindows ?? []).compactMap { $0.contentView }.flatMap(views) : []) }
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
   precondition(!views(panel).contains { $0.identifier?.rawValue == "calendar.notes.open" }, "Redundant quick-add button must be removed")
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
  let notePanel = CalendarPanel(firstWeekday:2, showWeeks:false, notesEnabled:true, date:date, notesStore:notesStore)
  let noteWindow = NSWindow(contentRect:notePanel.frame,styleMask:[.titled],backing:.buffered,defer:false)
  noteWindow.contentView = notePanel
  func noteButton(_ id: String) -> NSButton { views(notePanel).first { $0.identifier?.rawValue == id } as! NSButton }
  precondition(views(notePanel).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("calendar.day.") == true }.allSatisfy { $0.toolTip == nil }, "Floating preview must suppress all native date tooltips, including empty dates")
  notePanel.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:noteWindow.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!)
  precondition(notePanel.frame.width == 310, "Floating notes must not widen calendar")
  precondition(notePanel.containsCalendarWindow(noteWindow))
  precondition(notePanel.containsCalendarWindow(noteWindow.childWindows!.first!))
  let outsideWindow = NSWindow(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:false)
  precondition(!notePanel.containsCalendarWindow(outsideWindow), "Other app windows must count as outside")
  precondition(!notePanel.containsCalendarWindow(nil))
  let floatingFrame = noteWindow.childWindows!.first!.frame
  precondition(abs(floatingFrame.midY - noteWindow.frame.midY) < 1, "Floating notes must be vertically centered")
  precondition(floatingFrame.height < 240, "Empty editor should be compact")
  let input = views(notePanel).first { $0.identifier?.rawValue == "calendar.notes.input" } as! NSTextField
  let day = CalendarNotesStore.dayKey(date,calendar:calendar)
  input.stringValue = "买猫粮，顺路取快递"
  noteButton("calendar.notes.add").performClick(nil)
  precondition(notesStore.entries(on:day).count == 1 && input.stringValue.isEmpty)
  let compact = noteWindow.childWindows!.first!.contentView!
  compact.layoutSubtreeIfNeeded()
  let compactImage = compact.bitmapImageRepForCachingDisplay(in:compact.bounds)!
  compact.cacheDisplay(in:compact.bounds,to:compactImage)
  try compactImage.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/calendar-compact-task.png"))
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
  precondition(!notesView.isHidden && !input.isHiddenOrHasHiddenAncestor, "Click pins editable notes")
  notePanel.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:noteWindow.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!)
  precondition(input.stringValue.isEmpty)
  let original = model.days.firstIndex { calendar.isDate($0,inSameDayAs:date) }!
  noteButton("calendar.day.\(original)").performClick(nil)
  let doubleClick = NSEvent.mouseEvent(with:.leftMouseDown, location:.zero, modifierFlags:[], timestamp:0, windowNumber:noteWindow.windowNumber, context:nil, eventNumber:0, clickCount:2, pressure:1)!
  noteButton("calendar.day.\(original)").mouseDown(with:doubleClick)
  precondition(!notesView.isHidden && notePanel.frame.width == 310)
  precondition(input.stringValue == "还没输入完")
  for i in 1...15 { try notesStore.add("待办 \(i)：检查长文本在右侧自动换行，保持日期网格不变。",on:day) }
  notePanel.reload(); notePanel.layoutSubtreeIfNeeded()
  for appearance in [NSAppearance.Name.aqua,.darkAqua] {
   noteWindow.appearance = NSAppearance(named:appearance)
   notesView.window?.appearance = NSAppearance(named:appearance)
   notePanel.layoutSubtreeIfNeeded(); notePanel.displayIfNeeded()
   let rect = notesView.convert(input.bounds,from:input)
   precondition(notesView.bounds.contains(rect) && rect.width > 150)
   let text = views(notePanel).first { $0.identifier?.rawValue == "calendar.note.text.\(item.id)" }!
   let check = noteButton("calendar.note.toggle.\(item.id)")
   precondition(notePanel.convert(text.bounds,from:text).minX - notePanel.convert(check.bounds,from:check).maxX < 12, "Task text must align beside its checkbox")
   let notesBitmap = notesView.bitmapImageRepForCachingDisplay(in:notesView.bounds)!
   notesView.cacheDisplay(in:notesView.bounds,to:notesBitmap)
   try notesBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/calendar-floating-\(appearance.rawValue).png"))
   let bitmap = notePanel.bitmapImageRepForCachingDisplay(in:notePanel.bounds)!
   notePanel.cacheDisplay(in:notePanel.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/calendar-notes-\(appearance.rawValue).png"))
  }
  noteButton("calendar.note.delete.\(item.id)").performClick(nil)
  precondition(!notesStore.entries(on:day).contains { $0.id == item.id })
  noteButton("calendar.notes.close").performClick(nil)
  precondition(notePanel.frame.width == 310)
  noteButton("calendar.day.\(another)").performClick(nil)
  noteButton("calendar.notes.close").performClick(nil)
  let selectedBeforeHover = notePanel.selectedDate
  let focusBeforeHover = noteWindow.firstResponder
  let pointer = NSEvent.mouseEvent(with:.mouseMoved,location:.zero,modifierFlags:[],timestamp:0,windowNumber:noteWindow.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
  noteButton("calendar.day.\(original)").mouseEntered(with:pointer)
  noteButton("calendar.day.\(original)").mouseExited(with:pointer)
  RunLoop.main.run(until:Date().addingTimeInterval(0.4))
  precondition(notesView.isHidden, "Fast pointer passes must not open a card")
  noteButton("calendar.day.\(original)").mouseEntered(with:pointer)
  RunLoop.main.run(until:Date().addingTimeInterval(0.4))
  precondition(!notesView.isHidden, "Hover should preview existing notes")
  precondition(input.isHiddenOrHasHiddenAncestor && notePanel.selectedDate == selectedBeforeHover)
  precondition(noteWindow.firstResponder === focusBeforeHover, "Hover must not steal focus")
  precondition(notePanel.frame.width == 310)
  precondition(notesView.window !== noteWindow && notesView.window?.parent === noteWindow, "Notes must use a separate attached window")
  notePanel.layoutSubtreeIfNeeded()
  let hoverImage = notePanel.bitmapImageRepForCachingDisplay(in:notePanel.bounds)!
  notePanel.cacheDisplay(in:notePanel.bounds,to:hoverImage)
  try hoverImage.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/calendar-hover.png"))
  noteButton("calendar.day.\(original)").mouseExited(with:pointer)
  notesView.mouseEntered(with:pointer)
  RunLoop.main.run(until:Date().addingTimeInterval(0.3))
  precondition(!notesView.isHidden, "Preview remains while pointer enters card")
  noteButton("calendar.day.\(original)").performClick(nil)
  precondition(!input.isHiddenOrHasHiddenAncestor && calendar.isDate(notePanel.selectedDate,inSameDayAs:date))
  noteButton("calendar.day.\(another)").mouseEntered(with:pointer)
  RunLoop.main.run(until:Date().addingTimeInterval(0.35))
  precondition(!input.isHiddenOrHasHiddenAncestor, "Hover cannot replace an active editor")
  let floating = notesView.window!
  var requestedClose = false
  notePanel.onClose = { requestedClose = true }
  notePanel.mouseDown(with: NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:noteWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!)
  precondition(requestedClose, "Clicking calendar blank space must close the whole calendar group")
  precondition(!floating.isVisible && floating.parent == nil, "Closing calendar must dismiss the floating window")
  noteWindow.orderOut(nil)
  let infoView = views(notesView).first { $0.identifier?.rawValue == "calendar.notes.dateInfo" } as! NSTextField
  let makeupDate = calendar.date(from:DateComponents(year:2026,month:10,day:10,hour:12))!
  notesView.show(date:makeupDate,calendar:calendar,preview:true,showHolidays:true)
  precondition(infoView.stringValue.contains("九月初一") && infoView.stringValue.contains("调休上班"))
  notesView.show(date:makeupDate,calendar:calendar,preview:true,showHolidays:false)
  precondition(!infoView.stringValue.contains("调休"))
  var china = Calendar(identifier:.gregorian); china.timeZone = TimeZone(identifier:"Asia/Shanghai")!
  let termDate = china.date(from:DateComponents(year:2026,month:11,day:7,hour:12))!
  notesView.show(date:termDate,calendar:china,preview:true)
  precondition(infoView.stringValue.contains("立冬"))
  let tool = CalendarTool(defaults:defaults)
  precondition(!tool.showHolidays && !tool.notesEnabled)
  let settings = CalendarSettingsView(manager:tool)
  let notesToggle = views(settings).first { $0.identifier?.rawValue == "calendar.notesEnabled" } as! NSButton
  notesToggle.performClick(nil)
  precondition(CalendarTool(defaults:defaults).notesEnabled)
  notesToggle.performClick(nil)
  precondition(!CalendarTool(defaults:defaults).notesEnabled)
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
