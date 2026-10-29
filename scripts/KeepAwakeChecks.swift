import AppKit
import IOKit.pwr_mgt
@main struct KeepAwakeChecks {
    @MainActor static func main() throws {
        let suite = "awake.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = KeepAwake(defaults: defaults)
        defer { manager.stop() }
        precondition(!manager.active)
        try manager.addDuration(45); try manager.addDuration(45)
        precondition(manager.customMinutes == [45])
        precondition(KeepAwake(defaults: defaults).customMinutes == [45])
        for invalid in [-1, 0, 43201, Int.max] {
            do { try manager.addDuration(invalid); fatalError("Accepted invalid custom duration") } catch {}
        }
        try manager.start(minutes: 1)
        precondition(manager.active && manager.deadline != nil && manager.selectedMinutes == 1)
        func ownAssertions() -> [[String: Any]] {
            var result: Unmanaged<CFDictionary>?
            precondition(IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess)
            let dictionary = result!.takeRetainedValue() as NSDictionary
            return dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
        }
        func ours() -> [[String: Any]] { ownAssertions().filter { $0[kIOPMAssertionNameKey] as? String == "Light Tools — Keep Awake" } }
        precondition(ours().count == 1)
        precondition(ours()[0][kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypeNoIdleSleep)
        do { try manager.start(minutes: -1); fatalError("Accepted invalid start") } catch {}
        precondition(manager.active && ours().count == 1)
        try manager.start(minutes: 0)
        precondition(manager.deadline == nil && ours().count == 1 && manager.selectedMinutes == 0)
        manager.stop(); precondition(ours().isEmpty && manager.selectedMinutes == nil)
        ToolFeature.awake.setEnabled(false, in: defaults)
        do { try manager.start(minutes: 1); fatalError("Started disabled tool") } catch {}
        ToolFeature.awake.setEnabled(true, in: defaults)
        manager.removeDuration(45); precondition(manager.customMinutes.isEmpty)
        try manager.start(minutes: 1)
        // Let macOS enforce the real timeout; no synthetic time or sleep assertion mock.
        print("Checking actual 60-second power assertion timeout…")
        RunLoop.main.run(until: Date().addingTimeInterval(62))
        precondition(!manager.active && ours().isEmpty)
        print("PASS: real IOKit assertion type/create/replace/stop/60s expiry, disabled guard, custom duration validation/persistence")
    }
}
