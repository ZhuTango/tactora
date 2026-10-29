import AppKit
@main struct LidMonitorChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let name = "local.tango.lid-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var lid: Bool? = false
        var brightness: Float = 0.65
        var failWrite = false
        var writes: [(UInt32, Float)] = []
        let displays = [LidDisplayTarget(id: 1, frame: .zero, builtIn: true, mirrored: true),
                        LidDisplayTarget(id: 2, frame: .zero, builtIn: false, mirrored: true)]
        func makeMonitor() -> LidDisplaySleep {
            LidDisplaySleep(defaults: defaults, lidStateForTesting: { lid }, displaysForTesting: { displays },
                readBrightnessForTesting: { _ in brightness }, writeBrightnessForTesting: { id, value in
                    writes.append((id, value)); if failWrite { return false }; brightness = value; return true
                })
        }
        let monitor = makeMonitor()
        defaults.set(true, forKey: LidSleepPolicy.preferenceKey)
        monitor.refresh()
        lid = true; monitor.displaysChanged()
        precondition(brightness == 0)
        monitor.displaysChanged()
        lid = nil; monitor.displaysChanged(); precondition(brightness == 0)
        lid = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(brightness == 0.65, "Repeated close must not overwrite original")
        lid = true; monitor.displaysDidWake()
        brightness = 0.3; monitor.displaysDidWake(); precondition(brightness == 0)
        defaults.set(false, forKey: LidSleepPolicy.preferenceKey); monitor.refresh()
        precondition(brightness == 0.65)
        defaults.set(true, forKey: LidSleepPolicy.preferenceKey); monitor.refresh()
        failWrite = true; lid = false; monitor.displaysChanged()
        precondition(monitor.error != nil)
        failWrite = false; monitor.displaysChanged(); precondition(brightness == 0.65)
        lid = true; monitor.displaysChanged()
        let recovered = makeMonitor(); lid = false; recovered.refresh()
        precondition(brightness == 0.65, "Relaunch restores persisted original")
        precondition(writes.allSatisfy { $0.0 == 1 }, "Never write external brightness, even mirrored")
        recovered.stop(); monitor.stop()
        print("PASS: dim/restore, repeat-close, unknown lid, wake, disable, failed restore retry, crash recovery and external exclusion")
    }
}
