import Foundation
import ServiceManagement

/// Asynchronous XPC: neither device scanning nor UI actions block waiting for root.
@MainActor
final class KeyboardHelperBridge {
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
        guard Self.available else {
            disconnect()
            active = false
            message = Self.service.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中批准方寸辅助服务。" : "屏蔽内置键盘需要启用方寸辅助服务。"
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
