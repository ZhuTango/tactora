import AppKit
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationWillFinishLaunching(_ notification: Notification) { Thread.sleep(forTimeInterval: 1) }
    func showWindow() {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "Tactora Launch Check"
        window?.makeKeyAndOrderFront(nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.window?.orderOut(nil); self.window = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }
}
let app = NSApplication.shared
let delegate = Delegate(); app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
