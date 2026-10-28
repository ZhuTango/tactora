import AppKit
@main struct LidMonitorChecks {
    @MainActor static func main() {
        let name = "local.tango.lid-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let monitor = LidDisplaySleep(defaults: defaults, sleepForTesting: { calls += 1 })
        defaults.set(true, forKey: LidSleepPolicy.preferenceKey)
        monitor.refresh()
        precondition(monitor.error == nil, monitor.error ?? "")
        monitor.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 0, "Stopping cancels pending display sleep")
        defaults.set(false, forKey: LidSleepPolicy.preferenceKey)
        monitor.refresh()
        monitor.displaysDidWake()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 0)
        print("PASS: real IOKit registration, cleanup and disabled wake; actuator mocked")
    }
}
