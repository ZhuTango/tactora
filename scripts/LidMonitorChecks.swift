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
        defaults.set(true, forKey: LidSleepPolicy.preferenceKey)
        var lid = true
        var displays: [Bool]? = [true]
        let guarded = LidDisplaySleep(defaults: defaults, sleepForTesting: { calls += 1 },
            lidStateForTesting: { lid }, displaysForTesting: { displays })
        guarded.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 1, "Internal-only closed lid must sleep display")
        guarded.displaysDidWake()
        displays = [true, false]
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 1, "External connected during delay must block sleep")
        guarded.displaysChanged()
        guarded.displaysDidWake()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 1, "External display must stay untouched")
        displays = [true]
        guarded.displaysChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 2, "Disconnecting external while closed must recheck")
        guarded.displaysDidWake()
        lid = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(calls == 2, "Opening lid before action must cancel sleep")
        guarded.stop()
        print("PASS: internal-only sleep, hotplug guard, disconnect recheck and open-lid cancellation")
        print("PASS: real IOKit registration, cleanup and disabled wake; actuator mocked")
    }
}
