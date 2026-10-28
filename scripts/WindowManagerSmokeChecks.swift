import AppKit
@main struct WindowManagerSmokeChecks {
 @MainActor static func main() async throws {
  guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else { fatalError("Pass fixture PID") }
  guard AXIsProcessTrusted() else { print("SKIP: auxiliary test process lacks accessibility permission"); return }
  NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
  try await Task.sleep(nanoseconds: 500_000_000)
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("SKIP: fixture did not become frontmost"); return }
  let name = "window.smoke." + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let manager = WindowManager(defaults: defaults)
  let installed = CommandLine.arguments.contains("--installed")
  if !installed { manager.setEnabled(true) }
  defer { manager.setEnabled(false) }
  let app = AXUIElementCreateApplication(pid)
  var value: CFTypeRef?
  precondition(AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success)
  let window = value as! AXUIElement
  func frame() -> CGRect {
   var p: CFTypeRef?; var s: CFTypeRef?
   precondition(AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success)
   precondition(AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success)
   var point = CGPoint.zero; var size = CGSize.zero
   precondition(AXValueGetValue(p as! AXValue, .cgPoint, &point))
   precondition(AXValueGetValue(s as! AXValue, .cgSize, &size))
   return CGRect(origin: point, size: size)
  }
  let original = frame()
  let screen = NSScreen.screens.first!
  let area = CGRect(x: screen.visibleFrame.minX, y: screen.frame.maxY - screen.visibleFrame.maxY, width: screen.visibleFrame.width, height: screen.visibleFrame.height)
  for action in (installed ? [WindowLayout.left, .right, .maximize] : [.left, .right, .maximize, .topLeft, .center, .restore]) {
   guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("SKIP: focus changed; no other app modified"); return }
   let before = frame()
   if installed {
    let shortcut = action.defaultShortcut!
    let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false)!
    down.flags = [.maskControl, .maskAlternate, .maskCommand]
    up.flags = [.maskControl, .maskAlternate, .maskCommand]
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
   } else { manager.perform(action) }
   try await Task.sleep(nanoseconds: 500_000_000)
   let expected = action == .restore ? original : action.frame(in: area, current: before)
   let actual = frame()
   precondition(abs(actual.minX-expected.minX)<3 && abs(actual.minY-expected.minY)<3 && abs(actual.width-expected.width)<3 && abs(actual.height-expected.height)<3, "\(action): \(actual) vs \(expected), \(manager.status)")
  }
  print(installed ? "PASS: installed app hotkeys left/right/maximize changed fixture via AX" : "PASS: real AX fixture left/right/maximize/corner/center/restore")
 }
}
