import AppKit
import ServiceManagement
import SystemConfiguration

@MainActor final class FanService: NSObject, NSXPCListenerDelegate, FanHelperProtocol {
    let engine: FanEngine
    private var connection: NSXPCConnection?
    private var owner: uid_t = 0
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var lastUpdate: TimeInterval = 0
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static var competing: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.crystalidea.macsfancontrol" } }
    static var thermalOK: Bool { ProcessInfo.processInfo.thermalState == .nominal }
    init(engine: FanEngine) {
        self.engine = engine
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var uid: uid_t = 0; _ = SCDynamicStoreCopyConsoleUser(nil, &uid, nil)
                if uid != self.owner || Self.competing { self.engine.stop(reason: "会话变化或其他控速软件运行") }
                if Self.now - self.lastUpdate >= 2 {
                    self.lastUpdate = Self.now
                    self.engine.tick(now: Self.now, thermalOK: Self.thermalOK)
                }
                if self.connection == nil, !self.engine.active, !self.engine.recoveryPending { exit(EXIT_SUCCESS) }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop(reason: "系统即将睡眠") }
        }
    }
    nonisolated func configure(_ enabled: Bool, low: Double, high: Double, reply: @escaping (Bool, String) -> Void) {
        Task { @MainActor in
            if !enabled { self.engine.stop(reason: "温控已关闭"); reply(!self.engine.recoveryPending, self.engine.message); return }
            guard Self.thermalOK, !Self.competing else { reply(false, "请先退出其他控速软件，并等待系统热压力恢复正常。"); return }
            do { try self.engine.enable(curve: FanCurve(low: low, high: high), now: Self.now); reply(true, self.engine.message) }
            catch { reply(false, error.localizedDescription + " · " + self.engine.message) }
        }
    }
    nonisolated func heartbeat(reply: @escaping (Data?, String) -> Void) {
        Task { @MainActor in
            self.engine.renew(now: Self.now)
            var snapshot = self.engine.snapshot
            snapshot?.active = self.engine.active; snapshot?.message = self.engine.message
            reply(snapshot.flatMap { try? JSONEncoder().encode($0) }, self.engine.message)
        }
    }
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection candidate: NSXPCConnection) -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { accept(candidate) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { accept(candidate) } }
    }
    private func accept(_ candidate: NSXPCConnection) -> Bool {
        var uid: uid_t = 0; _ = SCDynamicStoreCopyConsoleUser(nil, &uid, nil)
        guard uid != 0, candidate.effectiveUserIdentifier == uid, connection == nil else { return false }
        owner = uid; connection = candidate
        candidate.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        candidate.exportedObject = self
        candidate.invalidationHandler = { [weak self] in Task { @MainActor in
            self?.engine.stop(reason: "温控连接已断开"); self?.connection = nil; self?.owner = 0
        } }
        candidate.interruptionHandler = candidate.invalidationHandler
        candidate.resume(); return true
    }
}
@main struct FanHelperMain {
    @MainActor static func main() throws {
        guard geteuid() == 0 else { throw FanControlError(message: "辅助程序必须通过系统服务启动。") }
        let directory = URL(fileURLWithPath: "/Library/Application Support/TactoraFanControl", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory, (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0 else {
            throw FanControlError(message: "恢复记录目录权限不正确。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let journal = directory.appendingPathComponent("owned.json")
        let owned: [Int]
        if FileManager.default.fileExists(atPath: journal.path) {
            owned = try JSONDecoder().decode([Int].self, from: Data(contentsOf: journal))
            guard owned.count <= 8, owned.allSatisfy({ (0...7).contains($0) }) else { throw FanControlError(message: "恢复记录无效。") }
        } else { owned = [] }
        let engine = FanEngine(hardware: try NativeFanHardware(), owned: owned) { ids in
            try JSONEncoder().encode(ids).write(to: journal, options: .atomic)
        }
        let delegate = FanService(engine: engine)
        let listener = NSXPCListener(machServiceName: FanHelperIdentity.label)
        listener.setConnectionCodeSigningRequirement(try FanHelperIdentity.requirement(identifier: "local.tango.macbglive"))
        listener.delegate = delegate; listener.resume()
        withExtendedLifetime(delegate) { RunLoop.main.run() }
    }
}
