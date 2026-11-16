import AppKit

@main struct AppLaunchChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var completed = 0
        for _ in 0..<2 {
            AppSwitcher.openApplication(at: url) { error in
                precondition(error == nil, "Launch failed: \(String(describing: error))")
                let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
                precondition(app?.isFinishedLaunching == true, "Completion must wait for the cold launch")
                precondition(app?.isTerminated == false)
                completed += 1
                if completed == 2 {
                    print("PASS: cold launch finishes before completion; repeated launch completes both callers")
                    guard app?.bundleIdentifier == "local.tango.tactora.launch-check" else { exit(0) }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        let suite = "tactora-launch-checks"
                        let defaults = UserDefaults(suiteName: suite)!
                        defaults.removePersistentDomain(forName: suite)
                        let manager = AppSwitcher(defaults: defaults, start: false)
                        let item = SwitcherApp(id: "local.tango.tactora.launch-check", name: "LaunchFixture", path: url.path)
                        try! manager.configure(item, shortcut: nil, show: true)
                        manager.activate(item.id)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                        precondition(windows.contains { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app!.processIdentifier) && ($0[kCGWindowLayer as String] as? Int) == 0 }, "Switching must reopen a window for a running windowless app")
                        defaults.removePersistentDomain(forName: suite)
                        print("PASS: switcher restores a window for a running windowless application")
                        exit(0)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { fatalError("Launch timed out") }
        RunLoop.main.run()
    }
}
