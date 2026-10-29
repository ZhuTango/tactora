import AppKit
import IOKit
import IOKit.pwr_mgt

struct LidDisplayTarget {
    let id: CGDirectDisplayID
    let frame: CGRect
    let builtIn: Bool
    var mirrored: Bool
}

/// Static opaque surface: no video, animation, focus changes or power commands.
@MainActor
final class LidBlackoutPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Consume clicks on the covered display without taking keyboard focus.
        ignoresMouseEvents = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LidDisplaySleep {
    private let defaults: UserDefaults
    private let lidStateOverride: (() -> Bool?)?
    private let displaysOverride: (() -> [LidDisplayTarget])?
    private let coverOverride: (([LidDisplayTarget]) -> Void)?
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var root: io_service_t = 0
    private var watchdog: Timer?
    private var panels: [CGDirectDisplayID: LidBlackoutPanel] = [:]
    private(set) var error: String?

    init(defaults: UserDefaults = .standard, lidStateForTesting: (() -> Bool?)? = nil,
         displaysForTesting: (() -> [LidDisplayTarget])? = nil,
         coverForTesting: (([LidDisplayTarget]) -> Void)? = nil) {
        self.defaults = defaults
        lidStateOverride = lidStateForTesting
        displaysOverride = displaysForTesting
        coverOverride = coverForTesting
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
        guard defaults.bool(forKey: LidSleepPolicy.preferenceKey), closed() == true else {
            apply([]); return
        }
        let candidates = displays()
        error = candidates.contains { $0.builtIn && $0.mirrored }
            ? "镜像显示时无法单独遮黑内屏 / Cannot cover only the built-in display while mirroring" : nil
        apply(candidates.filter { LidSleepPolicy.shouldCover(enabled: true, closed: true, builtIn: $0.builtIn, mirrored: $0.mirrored) })
    }

    private func apply(_ targets: [LidDisplayTarget]) {
        if let coverOverride { coverOverride(targets); return }
        let ids = Set(targets.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }
        for target in targets {
            let panel = panels[target.id] ?? LidBlackoutPanel(frame: target.frame)
            panels[target.id] = panel
            if panel.frame != target.frame { panel.setFrame(target.frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        apply([])
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if root != 0 { IOObjectRelease(root); root = 0 }
        error = nil
    }
}
