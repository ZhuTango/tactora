import Foundation
import AppKit
import SystemConfiguration

/// Root only holds built-in keyboard handles for a live, certificate-authenticated console-user lease.
@MainActor
final class ProtectionSession: NSObject, KeyboardHelperProtocol {
    let owner: uid_t
    let backend = NativeKeyboardBackend()
    private var externalIDs: [String] = []
    private var blocked: [KeyboardDevice] = []
    private var stopped = false
    private var expiry = Date.distantPast
    private var timer: Timer?
    init(owner: uid_t) {
        self.owner = owner
        super.init()
        backend.onDevicesChanged = { [weak self] in _ = self?.reconcile() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in _ = self?.reconcile() }
        }
        timer?.tolerance = 0.1
    }
    nonisolated func setProtection(_ externalIDs: [String], reply: @escaping (Bool, String) -> Void) {
        Task { @MainActor in
            guard !self.stopped else { reply(false, "连接已关闭。"); return }
            guard externalIDs.count <= 32, externalIDs.allSatisfy({ $0.utf8.count <= 512 }) else { reply(false, "无效的设备请求。"); return }
            self.externalIDs = externalIDs; self.expiry = Date().addingTimeInterval(15)
            let result = self.reconcile(); reply(result.0, result.1)
        }
    }
    func reconcile() -> (Bool, String) {
        var consoleUID: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
        guard consoleUID == owner, Date() < expiry, !externalIDs.isEmpty else {
            release(); return (false, "当前会话未请求屏蔽，内置键盘已释放。")
        }
        do {
            let devices = try backend.devices()
            guard devices.contains(where: { !$0.builtIn && externalIDs.contains($0.id) }) else {
                release(); return (false, "指定外置键盘未连接，内置键盘已恢复。")
            }
            let targets = devices.filter(\.builtIn)
            guard !targets.isEmpty else { release(); return (false, "未找到可单独屏蔽的内置键盘。") }
            for device in blocked where !targets.contains(device) { backend.unblock(device) }
            blocked.removeAll { !targets.contains($0) }
            for device in targets where !blocked.contains(device) { try backend.block(device); blocked.append(device) }
            return (true, "内置键盘已屏蔽。")
        } catch { release(); return (false, error.localizedDescription) }
    }
    private func release() { for device in blocked { backend.unblock(device) }; blocked = [] }
    func stop() { stopped = true; timer?.invalidate(); timer = nil; externalIDs = []; release() }
}

@MainActor final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private var liveConnection: NSXPCConnection?
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { accept(connection) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { accept(connection) } }
    }
    private func accept(_ connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
        guard connection.effectiveUserIdentifier == consoleUID, consoleUID != 0 else { return false }
        // XPC has already enforced the certificate + identifier requirement before this delegate runs.
        connection.exportedInterface = NSXPCInterface(with: KeyboardHelperProtocol.self)
        let session = ProtectionSession(owner: consoleUID)
        connection.exportedObject = session
        liveConnection?.invalidate(); liveConnection = connection
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                session.stop()
                if self?.liveConnection === connection {
                    self?.liveConnection = nil
                    // On-demand launchd service; no idle daemon after the app releases its lease.
                    exit(EXIT_SUCCESS)
                }
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
}

@main struct KeyboardHelperMain {
    @MainActor static func main() throws {
        guard geteuid() == 0 else { return }
        let listener = NSXPCListener(machServiceName: KeyboardHelperIdentity.label)
        listener.setConnectionCodeSigningRequirement(try KeyboardHelperIdentity.peerRequirement(identifier: KeyboardHelperIdentity.appIdentifier))
        let delegate = HelperDelegate()
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) { RunLoop.main.run() }
    }
}
