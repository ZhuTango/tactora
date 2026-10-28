import AppKit
import IOKit
import IOKit.pwr_mgt

/// Event-driven lid monitoring. No timer or persistent child process.
@MainActor
final class LidDisplaySleep {
    private let defaults: UserDefaults
    private let lidStateOverride: (() -> Bool?)?
    private let displaysOverride: (() -> [Bool]?)?
    private let testSleep: (() -> Void)?
    init(defaults: UserDefaults = .standard, sleepForTesting: (() -> Void)? = nil,
         lidStateForTesting: (() -> Bool?)? = nil, displaysForTesting: (() -> [Bool]?)? = nil) {
        self.defaults = defaults
        self.lidStateOverride = lidStateForTesting
        self.displaysOverride = displaysForTesting
        self.testSleep = sleepForTesting
    }
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var root: io_service_t = 0
    private var policy = LidSleepPolicy()
    private var pending: DispatchWorkItem?
    private var process: Process?
    private(set) var error: String?

    func refresh() {
        stop()
        guard defaults.bool(forKey: LidSleepPolicy.preferenceKey) else { return }
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            stop()
            error = "无法监听合盖状态 / Cannot monitor lid state"
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        // IOPM.h: iokit_family_msg(sub_iokit_powermanagement, 0x100).
        // Swift cannot import this function-like C macro.
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, type, _ in
            guard type == (UInt32(0xe0000000) | (13 << 14) | 0x100), let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<LidDisplaySleep>.fromOpaque(context).takeUnretainedValue().lidChanged()
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
        guard result == KERN_SUCCESS else {
            stop()
            error = "无法注册合盖通知 / Cannot register lid notifications"
            return
        }
        error = nil
        lidChanged()
    }

    private func closed() -> Bool? {
        if let lidStateOverride { return lidStateOverride() }
        guard root != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func canSleepInternalDisplay() -> Bool {
        if let displaysOverride {
            return LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn: displaysOverride())
        }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn:
            displays.prefix(Int(count)).map { CGDisplayIsBuiltin($0) != 0 })
    }

    func displaysChanged() {
        pending?.cancel(); pending = nil
        policy = LidSleepPolicy()
        lidChanged()
    }

    private func lidChanged() {
        let state = closed()
        if state != true { pending?.cancel(); pending = nil }
        if policy.update(enabled: defaults.bool(forKey: LidSleepPolicy.preferenceKey) && canSleepInternalDisplay(), closed: state) {
            scheduleSleep()
        }
    }

    /// Reapply only with the lid closed and no online external display.
    func displaysDidWake() {
        guard closed() == true, canSleepInternalDisplay(), defaults.bool(forKey: LidSleepPolicy.preferenceKey) else { return }
        scheduleSleep()
    }

    private func scheduleSleep() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closed() == true, self.canSleepInternalDisplay(),
                      self.defaults.bool(forKey: LidSleepPolicy.preferenceKey),
                      self.process?.isRunning != true else { return }
                if let testSleep = self.testSleep { testSleep(); return }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                task.arguments = ["displaysleepnow"]
                task.terminationHandler = { task in
                    if task.terminationStatus != 0 { NSLog("Display sleep command exited: %d", task.terminationStatus) }
                }
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                do { try task.run(); self.process = task }
                catch { self.error = error.localizedDescription; NSLog("Display sleep failed: %@", error.localizedDescription) }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func stop() {
        pending?.cancel(); pending = nil
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if root != 0 { IOObjectRelease(root); root = 0 }
        policy = LidSleepPolicy()
    }
}
