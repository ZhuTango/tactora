import Foundation
import ServiceManagement

@MainActor
func refreshKeyboardHelperRegistration(previous: String?, current: String,
    unregister: () async throws -> Void, register: () throws -> Void, save: () -> Void) async throws {
    guard previous != current else { return }
    try await unregister()
    try register()
    save()
}

/// Asynchronous XPC: neither device scanning nor UI actions block waiting for root.
@MainActor
final class KeyboardHelperBridge {
    private var registrationUpdating = false
    private var registrationAttempted = false
    private var registrationError: String?
    static let registrationKey = "keyboard.helperRegisteredBuild.v1"
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }
    static func recordRegistration() { UserDefaults.standard.set(currentBuild, forKey: registrationKey) }
    private var connection: NSXPCConnection?
    private var requested: [String] = []
    private var generation = 0
    private var requestCounter = 0
    private var retryAfter = Date.distantPast
    private var inFlight = false
    private var lastRequest = Date.distantPast
    private(set) var active = false
    private(set) var message = "等待辅助服务响应…"
    var onChange: (() -> Void)?
    static var service: SMAppService { .daemon(plistName: KeyboardHelperIdentity.plist) }
    static var available: Bool { service.status == .enabled }
    func configure(_ ids: [String]) {
        let ids = ids.sorted()
        if ids.isEmpty { disconnect(); return }
        if registrationUpdating { message = "正在更新屏蔽辅助服务…"; return }
        guard Self.available else {
            disconnect()
            active = false
            message = Self.service.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中批准方寸辅助服务。" : "屏蔽内置键盘需要启用方寸辅助服务。"
            return
        }
        if UserDefaults.standard.string(forKey: Self.registrationKey) != Self.currentBuild {
            if registrationAttempted {
                message = registrationError ?? "辅助服务更新失败，请重新启动方寸重试。"
                return
            }
            registrationAttempted = true; registrationUpdating = true
            disconnect(); message = "正在更新屏蔽辅助服务…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let service = Self.service
                    try await refreshKeyboardHelperRegistration(
                        previous: UserDefaults.standard.string(forKey: Self.registrationKey), current: Self.currentBuild,
                        unregister: { try await service.unregister() },
                        register: { try service.register() }, save: { Self.recordRegistration() })
                } catch {
                    self.registrationError = "辅助服务更新失败：" + error.localizedDescription
                    if Self.service.status == .requiresApproval {
                        self.registrationError = "请在系统设置 → 通用 → 登录项中批准方寸辅助服务。"
                    }
                    self.message = self.registrationError!
                }
                self.registrationUpdating = false
                self.onChange?()
            }
            return
        }
        guard Date() >= retryAfter else { return }
        if inFlight || (requested == ids && Date().timeIntervalSince(lastRequest) < 3) { return }
        requested = ids; lastRequest = Date(); inFlight = true
        let current = generation
        requestCounter += 1
        let request = requestCounter
        do {
            if connection == nil {
                let requirement = try KeyboardHelperIdentity.peerRequirement(identifier: KeyboardHelperIdentity.label)
                let candidate = NSXPCConnection(machServiceName: KeyboardHelperIdentity.label, options: .privileged)
                candidate.remoteObjectInterface = NSXPCInterface(with: KeyboardHelperProtocol.self)
                candidate.setCodeSigningRequirement(requirement)
                candidate.invalidationHandler = { [weak self] in Task { @MainActor in self?.failed("辅助服务连接已断开，屏蔽已释放。", generation: current) } }
                candidate.interruptionHandler = { [weak self] in Task { @MainActor in self?.failed("辅助服务已中断，屏蔽已释放。", generation: current) } }
                candidate.resume(); connection = candidate
            }
            let proxy = connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
                Task { @MainActor in self?.failed(error.localizedDescription, generation: current) }
            } as? KeyboardHelperProtocol
            guard let proxy else { throw KeyboardControlError(message: "无法连接方寸辅助服务。") }
            proxy.setProtection(ids) { [weak self] active, message in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    self.inFlight = false; self.active = active; self.message = message
                    self.onChange?()
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.generation == current, self.requestCounter == request, self.inFlight else { return }
                self.failed("辅助服务响应超时，已断开连接以恢复键盘。", generation: current)
            }
        } catch { failed(error.localizedDescription, generation: current) }
    }
    private func failed(_ reason: String, generation: Int) {
        guard self.generation == generation else { return }
        disconnect(); retryAfter = Date().addingTimeInterval(5); message = reason; onChange?()
    }
    func disconnect() {
        guard connection != nil || !requested.isEmpty || active else { return }
        generation += 1; inFlight = false; requested = []; active = false
        let old = connection; connection = nil; old?.invalidate()
    }
}
