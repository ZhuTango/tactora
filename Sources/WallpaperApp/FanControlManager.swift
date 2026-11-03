import AppKit
import ServiceManagement

@MainActor final class FanControlManager {
    private let defaults: UserDefaults
    private let serviceEnabled: () -> Bool
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
    var shouldMonitor: (() -> Bool)?
    var enabled: Bool { ToolFeature.fans.isEnabled(in: defaults) }
    var curve: FanCurve {
        let low = defaults.object(forKey: "fans.low") as? Double ?? 50
        let high = defaults.object(forKey: "fans.high") as? Double ?? 85
        let value = FanCurve(low: low, high: high)
        return value.valid ? value : FanCurve()
    }
    static var service: SMAppService { .daemon(plistName: FanHelperIdentity.plist) }
    init(defaults: UserDefaults = .standard, serviceEnabled: @escaping () -> Bool = {
        SMAppService.daemon(plistName: FanHelperIdentity.plist).status == .enabled
    }) { self.defaults = defaults; self.serviceEnabled = serviceEnabled }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            self?.disconnect(); self?.active = false
        } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            if self?.enabled == true { self?.connectAndConfigure() }
        } })
        if enabled { setEnabled(true) }
    }
    func setEnabled(_ value: Bool) {
        requested = value
        preserveControlStatus = true
        ToolFeature.fans.setEnabled(false, in: defaults)
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
        do {
            try Self.service.register()
            message = Self.service.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许方寸风扇辅助服务。" : "辅助服务已注册。"
            if enabled || requested { connectAndConfigure() }
        } catch { message = error.localizedDescription }
        changed()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func connectAndConfigure() {
        guard requested || enabled else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
            message = "Macs Fan Control 正在运行，请先恢复自动模式并退出它。"; changed(); return
        }
        guard serviceEnabled() else {
            message = Self.service.status == .requiresApproval ? "等待系统批准风扇辅助服务。" : "请先点击“授权辅助服务”，再开启温控。"
            changed(); return
        }
        do {
            if connection == nil {
                let candidate = NSXPCConnection(machServiceName: FanHelperIdentity.label, options: .privileged)
                candidate.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
                candidate.setCodeSigningRequirement(try FanHelperIdentity.requirement(identifier: FanHelperIdentity.label))
                candidate.invalidationHandler = { [weak self, weak candidate] in Task { @MainActor in
                    guard let self, let candidate, self.connection === candidate else { return }
                    self.connection = nil; self.active = false; self.inFlight = false
                    ToolFeature.fans.setEnabled(false, in: self.defaults)
                    self.message = "辅助服务连接中断；服务会尝试恢复系统控制，请重新开启。"; self.changed()
                } }
                candidate.interruptionHandler = candidate.invalidationHandler
                connection = candidate; candidate.resume()
            }
            let token = generation
            proxy()?.configure(true, low: curve.low, high: curve.high) { [weak self] ok, status in Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.active = ok; self.requested = false
                ToolFeature.fans.setEnabled(ok, in: self.defaults)
                self.message = status; self.changed()
            } }
        } catch { message = error.localizedDescription; changed() }
    }
    private func proxy() -> FanHelperProtocol? {
        let token = generation
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in Task { @MainActor in
            guard let self, token == self.generation else { return }
            self.active = false; self.inFlight = false; ToolFeature.fans.setEnabled(false, in: self.defaults); self.message = "辅助服务无响应：" + error.localizedDescription; self.changed()
        } } as? FanHelperProtocol
    }
    func poll() {
        if connection != nil, !inFlight {
            inFlight = true; let token = generation
            proxy()?.heartbeat { [weak self] data, status in Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.inFlight = false
                if let data, let value = try? JSONDecoder().decode(FanSnapshot.self, from: data) {
                    self.snapshot = value; self.active = value.active
                    if !value.active { ToolFeature.fans.setEnabled(false, in: self.defaults) }
                }
                self.message = status; self.changed()
            } }
        }
        guard (enabled || shouldMonitor?() == true), !reading else { return }
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
    private func disconnect() { generation += 1; connection?.invalidate(); connection = nil; inFlight = false; active = false }
    private func changed() { onChange?() }
}
