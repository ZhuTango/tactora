import AppKit
@main struct FanUIChecks {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let defaults = UserDefaults(suiteName: "tactora-fan-ui-checks")!
  defaults.removePersistentDomain(forName: "tactora-fan-ui-checks")
  defer { defaults.removePersistentDomain(forName: "tactora-fan-ui-checks") }
  let manager = FanControlManager(defaults: defaults, serviceEnabled: { false })
  manager.setEnabled(true)
  precondition(!manager.enabled && !manager.active, "Unauthorized or blocked activation must stay off")
  manager.setEnabled(false)
  let recoveryMessage = manager.message
  manager.shouldMonitor = { true }; manager.poll()
  RunLoop.main.run(until: Date().addingTimeInterval(0.5))
  precondition(manager.message == recoveryMessage, "Read-only polling must not overwrite recovery status")
  let view = FanSettingsView(manager: manager)
  let window = NSWindow(contentRect: NSRect(x:0,y:0,width:780,height:580), styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = view
  window.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
  let controls = all(view)
  let toggle = controls.first { $0.identifier?.rawValue == "fans.enabled" } as! NSSwitch
  precondition(toggle.state == .off)
  let low = controls.first { $0.identifier?.rawValue == "fans.low" } as! NSTextField
  let high = controls.first { $0.identifier?.rawValue == "fans.high" } as! NSTextField
  low.stringValue = "80"; high.stringValue = "85"
  let apply = controls.compactMap { $0 as? NSButton }.first { $0.title == "应用" || $0.title == "Apply" }!
  apply.sendAction(apply.action!, to: apply.target)
  precondition(manager.curve == FanCurve())
  precondition(low.stringValue == "80", "Invalid input stays editable")
  low.stringValue = "55"; high.stringValue = "90"; apply.sendAction(apply.action!, to: apply.target)
  precondition(manager.curve == FanCurve(low:55,high:90))
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
   window.appearance = NSAppearance(named: appearance)
   window.makeKeyAndOrderFront(nil)
   NSApp.activate(ignoringOtherApps: true)
   RunLoop.main.run(until: Date().addingTimeInterval(0.1))
   view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
   for control in controls where control is NSControl {
    let frame = view.convert(control.bounds, from: control)
    precondition(frame.minX >= 0 && frame.maxX <= view.bounds.maxX + 1 && frame.minY >= 0 && frame.maxY <= view.bounds.maxY + 1, "Clipped fan control: \(frame)")
   }
   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
   view.cacheDisplay(in: view.bounds, to: bitmap)
   try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/fans-\(appearance.rawValue).png"))
   if CommandLine.arguments.contains("--screenshots") {
    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), ".build/fans-window-\(appearance.rawValue).png"]
    try capture.run(); capture.waitUntilExit()
   }
  }
  print("Fan UI default-off, invalid input retention, persistence and light/dark layout checks passed")
 }
}
