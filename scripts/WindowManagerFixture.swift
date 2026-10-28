import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 600, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Light Tools — Window Test"
window.isReleasedWhenClosed = false
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in app.terminate(nil) }
app.run()
