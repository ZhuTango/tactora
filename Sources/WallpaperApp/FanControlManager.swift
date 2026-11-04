import AppKit
import ServiceManagement

@MainActor
func refreshFanHelperRegistration(previous: String?, current: String,
    unregister: () async throws -> Void, register: () throws -> Void, save: () -> Void) async throws {
    guard previous != current else { return }
    try await unregister()
    for attempt in 0..<3 {
        do { try register(); save(); return }
        catch {
            let error = error as NSError
            guard error.domain == "SMAppServiceErrorDomain", error.code == 1, attempt < 2 else { throw error }
            // ServiceManagement can finish unregistering before its registration state settles.
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

/// Bounded retry frequency, without a terminal retry count. No hardware writes here.
struct FanConnectionRecovery {
    static let configurationTimeout: TimeInterval = 30
    private var delay: TimeInterval = 0
    private var nextAttempt = Date.distantPast
    func canAttempt(at now: Date) -> Bool { now >= nextAttempt }
    mutating func reset() { delay = 0; nextAttempt = .distantPast }
    mutating func scheduleRetry(after now: Date) {
        delay = delay == 0 ? 10 : min(60, delay * 2)
        deferRetry(after: now)
    }
    mutating func deferRetry(after now: Date) {
        nextAttempt = now.addingTimeInterval(max(10, delay))
    }
}

@MainActor final class FanControlManager {
    private static let registrationKey = "fans.helperRegisteredBuild.v1"
    private static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }
    private var registrationUpdating = false
    private var configuring = false
    private var recovery = FanConnectionRecovery()
    private var configureTimeout: Task<Void, Never>?
    private var sleeping = false
    private let defaults: UserDefaults
    private let serviceEnabled: () -> Bool
    private let now: () -> Date
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var requested = false
    private var preserveControlStatus = false
    private let readQueue = DispatchQueue(label: "local.tango.fan-read", qos: .utility)
    private var reading = false
    private(set) var snapshot: FanSnapshot?
    private(set) var message = "系统自动控制"
    private(set) var active = false
    var onChange: (() -> Void)?
    var onTelemetryChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var showInMenu: Bool { defaults.object(forKey: "fans.showInMenu") as? Bool ?? true }
    var showInMenuBar: Bool { defaults.bool(forKey: "fans.showInMenuBar") }
    func setDisplay(menu: Bool, menuBar: Bool) {
        defaults.set(menu, forKey: "fans.showInMenu")
        defaults.set(menuBar, forKey: "fans.showInMenuBar")
        onDisplayChange?(); changed(); poll()
    }
    var menuVisible = false
    var menuTitle: String {
        guard let snapshot, let temperature = snapshot.maximumTemperature else {
            return AppLanguage.english ? "CPU —°C · Fans — RPM" : "CPU —°C · 风扇 — RPM"
        }
        let speeds = snapshot.fans.sorted { $0.id < $1.id }.map { String(Int($0.actual.rounded())) }.joined(separator: " / ")
        return (enabled && !active ? (AppLanguage.english ? "Paused · " : "温控暂停 · ") : "") + String(format: "CPU %.1f°C · ", temperature) + (AppLanguage.english ? "Fans " : "风扇 ") + speeds + " RPM"
    }
    var shouldMonitor: (() -> Bool)?
    var enabled: Bool { ToolFeature.fans.isEnabled(in: defaults) }
    var curve: FanCurve {
        let low = defaults.object(forKey: "fans.low") as? Double ?? 50
        let high = defaults.object(forKey: "fans.high") as? Double ?? FanCurve().high
        let value = FanCurve(low: low, high: high)
        return value.valid ? value : FanCurve()
    }
    static var service: SMAppService { .daemon(plistName: FanHelperIdentity.plist) }
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, serviceEnabled: @escaping () -> Bool = {
        SMAppService.daemon(plistName: FanHelperIdentity.plist).status == .enabled
    }) { self.defaults = defaults; self.now = now; self.serviceEnabled = serviceEnabled }
    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            self?.sleeping = true; self?.disconnect(); self?.active = false
        } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            self?.sleeping = false; self?.recovery.reset()
            if self?.enabled == true { self?.connectAndConfigure() }
        } })
        if enabled { setEnabled(true) }
        else if serviceEnabled(), defaults.string(forKey: Self.registrationKey) != Self.currentBuild { authorize() }
    }
    func setEnabled(_ value: Bool) {
        generation += 1; configuring = false; inFlight = false
        recovery.reset()
        requested = value
        preserveControlStatus = true
        ToolFeature.fans.setEnabled(value, in: defaults)
        if value { connectAndConfigure() }
        else {
            generation += 1; inFlight = false
            guard let proxy = proxy() else { active = false; message = "已关闭；辅助服务失联时会在 6 秒租约超时后尝试恢复系统控制。"; changed(); return }
            let token = generation
            proxy.configure(false, low: curve.low, high: curve.high) { [weak self] ok, status in Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.active = false; self.message = status; self.changed()
                if ok { self.disconnect(); self.preserveControlStatus = false }
            } }
        }
        changed()
    }
    func saveCurve(_ value: FanCurve) -> Bool {
        guard value.valid else { message = "温度需在 40–95°C 之间，且至少相差 10°C。"; changed(); return false }
        defaults.set(value.low, forKey: "fans.low"); defaults.set(value.high, forKey: "fans.high")
        if enabled || requested { connectAndConfigure() }
        changed(); return true
    }
    func authorize() {
        guard !registrationUpdating else { return }
        preserveControlStatus = true
        registrationUpdating = true
        let resume = enabled || requested
        disconnect(); requested = resume
        message = "正在更新风扇辅助服务…"; changed()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let service = Self.service
                if service.status == .enabled || service.status == .requiresApproval {
                    try await refreshFanHelperRegistration(previous: self.defaults.string(forKey: Self.registrationKey), current: Self.currentBuild,
                        unregister: { try await service.unregister() }, register: { try service.register() },
                        save: { self.defaults.set(Self.currentBuild, forKey: Self.registrationKey) })
                } else {
                    try service.register()
                    self.defaults.set(Self.currentBuild, forKey: Self.registrationKey)
                }
                self.registrationUpdating = false
                self.message = service.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许方寸风扇辅助服务。" : "辅助服务已注册。"
                if self.requested { self.connectAndConfigure() }
            } catch {
                self.registrationUpdating = false
                self.message = "辅助服务更新失败：" + error.localizedDescription
            }
            self.changed()
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func connectAndConfigure() {
        guard requested || enabled else { return }
        guard !registrationUpdating, !configuring, !sleeping else { return }
        recovery.scheduleRetry(after: now())
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
            message = "Macs Fan Control 正在运行，请先恢复自动模式并退出它。"; changed(); return
        }
        guard serviceEnabled() else {
            message = Self.service.status == .requiresApproval ? "等待系统批准风扇辅助服务。" : "请先点击“授权辅助服务”，再开启温控。"
            changed(); return
        }
        if defaults.string(forKey: Self.registrationKey) != Self.currentBuild { authorize(); return }
        do {
            if connection == nil {
                let candidate = NSXPCConnection(machServiceName: FanHelperIdentity.label, options: .privileged)
                candidate.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
                candidate.setCodeSigningRequirement(try FanHelperIdentity.requirement(identifier: FanHelperIdentity.label))
                candidate.invalidationHandler = { [weak self, weak candidate] in Task { @MainActor in
                    guard let self, let candidate, self.connection === candidate else { return }
                    self.disconnect()
                    self.message = "辅助服务连接中断，正在等待自动恢复。"; self.changed()
                } }
                candidate.interruptionHandler = candidate.invalidationHandler
                connection = candidate; candidate.resume()
            }
            configureTimeout?.cancel()
            generation += 1; inFlight = false
            configuring = true
            message = "正在连接风扇辅助服务…"; changed()
            let token = generation
            configureTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(FanConnectionRecovery.configurationTimeout * 1_000_000_000)) }
                catch { return }
                guard let self, token == self.generation, self.configuring else { return }
                self.disconnect(); self.message = "辅助服务响应超时，等待自动重连。"; self.changed()
            }
            proxy()?.configure(true, low: curve.low, high: curve.high) { [weak self] ok, status in Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.configureTimeout?.cancel(); self.configureTimeout = nil
                self.configuring = false; self.active = ok
                if ok { self.recovery.reset() }
                self.recovery.deferRetry(after: self.now())
                self.message = status; self.changed()
            } }
        } catch { message = error.localizedDescription; changed() }
    }
    private func proxy() -> FanHelperProtocol? {
        let token = generation
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in Task { @MainActor in
            guard let self, token == self.generation else { return }
            self.disconnect(); self.message = "辅助服务无响应：" + error.localizedDescription; self.changed()
        } } as? FanHelperProtocol
    }
    func poll() {
        if enabled, !active, !configuring, !registrationUpdating, !sleeping,
           recovery.canAttempt(at: now()) {
            connectAndConfigure()
        }
        if connection != nil, !inFlight {
            inFlight = true; let token = generation
            proxy()?.heartbeat { [weak self] data, status in Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.inFlight = false
                if let data, let value = try? JSONDecoder().decode(FanSnapshot.self, from: data) {
                    self.snapshot = value; self.active = value.active
                }
                self.message = status; self.changed()
            } }
        }
        guard (enabled || showInMenuBar || menuVisible || shouldMonitor?() == true), !reading else { return }
        reading = true
        readQueue.async { [weak self] in
            let result = Result { try FanSMC().snapshot() }
            Task { @MainActor in
                guard let self else { return }; self.reading = false
                switch result {
                case .success(var value):
                    value.active = self.active; self.snapshot = value
                    if !self.enabled && self.connection == nil && !self.preserveControlStatus { self.message = value.fans.contains { $0.mode == 1 } ? "其他程序或遗留设置正在手动控速" : "系统自动控制" }
                case .failure(let error): if !self.active { if !self.preserveControlStatus { self.message = error.localizedDescription }; self.snapshot = nil }
                }
                self.changed()
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; disconnect(); for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }; observers = [] }
    private func disconnect() {
        configureTimeout?.cancel(); configureTimeout = nil
        generation += 1
        let old = connection; connection = nil; old?.invalidate()
        inFlight = false; configuring = false; active = false
        recovery.deferRetry(after: now())
    }
    private func changed() { onChange?(); onTelemetryChange?() }
}
