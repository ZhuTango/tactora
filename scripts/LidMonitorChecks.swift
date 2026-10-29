import AppKit
@main struct LidMonitorChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let name = "local.tango.lid-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var lid: Bool? = true
        var displays = [LidDisplayTarget(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), builtIn: true, mirrored: false),
                        LidDisplayTarget(id: 2, frame: CGRect(x: 800, y: 0, width: 800, height: 600), builtIn: false, mirrored: false)]
        var shown: [LidDisplayTarget] = []
        let monitor = LidDisplaySleep(defaults: defaults, lidStateForTesting: { lid },
            displaysForTesting: { displays }, coverForTesting: { shown = $0 })
        defaults.set(true, forKey: LidSleepPolicy.preferenceKey)
        monitor.refresh()
        precondition(monitor.error == nil)
        precondition(shown.map(\.id) == [1], "Cover internal even when external is connected")
        lid = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(shown.isEmpty, "Watchdog uncovers if the open notification was missed")
        lid = true; monitor.displaysDidWake()
        precondition(shown.map(\.id) == [1], "Wake while closed reapplies")
        displays[0].mirrored = true; monitor.displaysChanged()
        precondition(shown.isEmpty, "Never black out a mirrored external screen")
        displays.removeFirst(); monitor.displaysChanged()
        precondition(shown.isEmpty, "Never relocate cover onto external display")
        displays = [LidDisplayTarget(id: 1, frame: .zero, builtIn: true, mirrored: false)]
        monitor.displaysChanged(); precondition(shown.count == 1)
        lid = nil; monitor.displaysChanged(); precondition(shown.isEmpty)
        lid = true; monitor.displaysChanged()
        defaults.set(false, forKey: LidSleepPolicy.preferenceKey); monitor.refresh()
        precondition(shown.isEmpty)
        monitor.stop()
        let panel = LidBlackoutPanel(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        precondition(panel.backgroundColor == .black && panel.isOpaque && !panel.hasShadow)
        precondition(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate)
        precondition(panel.level.rawValue > NSWindow.Level.screenSaver.rawValue)
        precondition(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        print("PASS: internal-only blackout, external/mirror exclusion, wake/hotplug, open/unknown/disable cleanup and black panel configuration")
    }
}
