import AppKit
import IOKit
import IOKit.pwr_mgt

struct LidDisplayTarget {
    let id: CGDirectDisplayID
    let frame: CGRect
    let builtIn: Bool
    var mirrored: Bool
}

/// DisplayServices targets one physical display, including in mirror mode.
/// Resolve at runtime so unsupported systems fail without altering brightness.
private enum BuiltInBrightness {
    typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (UInt32, Float) -> Int32
    static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    static func read(_ id: UInt32) -> Float? {
        guard let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        guard unsafeBitCast(symbol, to: Get.self)(id, &value) == 0,
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    static func write(_ id: UInt32, _ value: Float) -> Bool {
        guard let library, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return false }
        return unsafeBitCast(symbol, to: Set.self)(id, value) == 0
    }
}

@MainActor
final class LidDisplaySleep {
    private let defaults: UserDefaults
    private let lidStateOverride: (() -> Bool?)?
    private let displaysOverride: (() -> [LidDisplayTarget])?
    private let readBrightness: (UInt32) -> Float?
    private let writeBrightness: (UInt32, Float) -> Bool
    private static let savedKey = "lidOriginalBuiltInBrightness"
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var root: io_service_t = 0
    private var watchdog: Timer?
    private(set) var error: String?

    init(defaults: UserDefaults = .standard, lidStateForTesting: (() -> Bool?)? = nil,
         displaysForTesting: (() -> [LidDisplayTarget])? = nil,
         readBrightnessForTesting: ((UInt32) -> Float?)? = nil,
         writeBrightnessForTesting: ((UInt32, Float) -> Bool)? = nil) {
        self.defaults = defaults
        lidStateOverride = lidStateForTesting
        displaysOverride = displaysForTesting
        readBrightness = readBrightnessForTesting ?? BuiltInBrightness.read
        writeBrightness = writeBrightnessForTesting ?? BuiltInBrightness.write
    }

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
        // IOKit notifications are primary; a cheap read catches missed transitions.
        // Enabled only with this feature, no subprocess and no display rendering loop.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lidChanged() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func closed() -> Bool? {
        if let lidStateOverride { return lidStateOverride() }
        guard root != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func displays() -> [LidDisplayTarget] {
        if let displaysOverride { return displaysOverride() }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return LidDisplayTarget(id: id, frame: screen.frame, builtIn: CGDisplayIsBuiltin(id) != 0,
                                    mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }

    func displaysChanged() { lidChanged() }
    func displaysDidWake() { lidChanged() }

    private func lidChanged() {
        guard defaults.bool(forKey: LidSleepPolicy.preferenceKey) else { restore(); return }
        guard let isClosed = closed() else { return }
        guard isClosed else { restore(); return }
        guard let target = displays().first(where: { $0.builtIn }) else { return }
        guard let current = readBrightness(target.id) else {
            error = "无法读取内屏亮度 / Cannot read built-in display brightness"; return
        }
        if defaults.object(forKey: Self.savedKey) == nil {
            // Persist before changing hardware so a crash/relaunch can recover.
            defaults.set(current, forKey: Self.savedKey)
            defaults.synchronize()
        }
        if current > 0.001 && !writeBrightness(target.id, 0) {
            error = "无法降低内屏亮度 / Cannot dim built-in display"; return
        }
        error = nil
    }

    private func restore() {
        guard let saved = defaults.object(forKey: Self.savedKey) as? NSNumber,
              let target = displays().first(where: { $0.builtIn }) else { return }
        let value = saved.floatValue
        guard value.isFinite, (0...1).contains(value), writeBrightness(target.id, value) else {
            error = "无法恢复内屏亮度，将保留原值以便重试 / Brightness restore failed; original retained"; return
        }
        defaults.removeObject(forKey: Self.savedKey)
        defaults.synchronize()
        error = nil
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        restore()
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if root != 0 { IOObjectRelease(root); root = 0 }
    }
}
