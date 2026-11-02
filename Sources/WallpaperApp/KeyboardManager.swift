import AppKit
import IOKit.hid
import IOKit.hidsystem

/// Uses Apple's TN2450 per-service mapping API and IOHID exclusive device handles.
/// No event tap, virtual keyboard, driver extension, or Karabiner dependency.
/// Exclusive built-in keyboard access uses our narrowly scoped SMAppService helper.
@MainActor
final class NativeKeyboardBackend: KeyboardBackend {
    var onHelperChanged: (() -> Void)?
    var onDevicesChanged: (() -> Void)?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var handles: [String: IOHIDDevice] = [:]
    private var services: [String: IOHIDServiceClient] = [:]
    private var helper: KeyboardHelperBridge?
    private var seized: [String: IOHIDDevice] = [:]
    init() {
        if geteuid() != 0 {
            helper = KeyboardHelperBridge()
            helper?.onChange = { [weak self] in self?.onHelperChanged?() }
        }
        IOHIDManagerSetDeviceMatching(manager, ["DeviceUsagePage": 1, "DeviceUsage": 6] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let backend = Unmanaged<NativeKeyboardBackend>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak backend] in backend?.onDevicesChanged?() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
    deinit {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        for handle in seized.values { IOHIDDeviceClose(handle, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
    }
    func devices() throws -> [KeyboardDevice] {
        let raw = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let serviceList = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        handles = [:]; services = [:]
        var result: [KeyboardDevice] = []
        for device in raw {
            func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
            let name = property("Product") as? String ?? "Keyboard"
            let transport = property("Transport") as? String ?? "Unknown"
            guard !name.lowercased().contains("virtual"), !transport.lowercased().contains("virtual"),
                  !name.lowercased().contains("karabiner"), !IOHIDDeviceConformsTo(device, 1, 2),
                  IOHIDDeviceConformsTo(device, 1, 6) else { continue }
            let builtIn = (property("Built-In") as? NSNumber)?.boolValue == true
            let vendor = (property("VendorID") as? NSNumber)?.uint64Value ?? 0
            let product = (property("ProductID") as? NSNumber)?.uint64Value ?? 0
            let location = ((property("LocationID") as? NSNumber)?.uint64Value ?? 0) & 0xffffffff
            let serial = (property("SerialNumber") as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (property("DeviceAddress") as? String).flatMap { $0.isEmpty ? nil : $0 }
            let identity = builtIn ? "builtin" : serial ?? "location:\(location)"
            let id = "\(vendor):\(product):\(transport):\(identity)"
            let candidates = serviceList.filter { service in
                guard IOHIDServiceClientConformsTo(service, 1, 6) != 0 else { return false }
                func number(_ key: String) -> UInt64 { (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.uint64Value ?? 0 }
                return number("VendorID") == vendor && number("ProductID") == product && (number("LocationID") & 0xffffffff) == location
            }
            // Ambiguous devices are not silently combined: never apply one device's map to another.
            guard candidates.count == 1, let service = candidates.first,
                  let connection = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { continue }
            handles[id] = device; services[id] = service
            result.append(KeyboardDevice(id: id, name: name, transport: transport, builtIn: builtIn, connectionID: connection.uint64Value))
        }
        let duplicates = Set(Dictionary(grouping: result, by: \.id).filter { $0.value.count > 1 }.keys)
        for id in duplicates { handles.removeValue(forKey: id); services.removeValue(forKey: id) }
        return result.filter { !duplicates.contains($0.id) }.sorted { ($0.builtIn ? 0 : 1, $0.name) < ($1.builtIn ? 0 : 1, $1.name) }
    }
    func mappings(for device: KeyboardDevice) throws -> [KeyboardMapping] {
        guard let service = services[device.id] else { throw KeyboardControlError(message: "键盘已断开。") }
        guard let raw = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
        guard let maps = raw as? [[String: NSNumber]] else { throw KeyboardControlError(message: "无法读取系统键位映射，未做修改。") }
        return try maps.map {
            guard let from = $0["HIDKeyboardModifierMappingSrc"], let to = $0["HIDKeyboardModifierMappingDst"] else {
                throw KeyboardControlError(message: "系统键位格式无法识别，未做修改。")
            }
            return KeyboardMapping(source: from.uint64Value, destination: to.uint64Value)
        }
    }
    func setMappings(_ mappings: [KeyboardMapping], for device: KeyboardDevice) throws {
        guard let service = services[device.id] else { throw KeyboardControlError(message: "键盘已断开。") }
        let value = mappings.map { ["HIDKeyboardModifierMappingSrc": NSNumber(value: $0.source), "HIDKeyboardModifierMappingDst": NSNumber(value: $0.destination)] }
        guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, value as CFArray),
              try self.mappings(for: device) == mappings else {
            throw KeyboardControlError(message: "macOS 未接受键位映射。请检查输入监控权限或其他键盘工具。")
        }
    }
    func prepareProtection(_ externals: [KeyboardDevice]) { helper?.configure(externals.map(\.id)) }
    func block(_ device: KeyboardDevice) throws {
        guard device.builtIn else { throw KeyboardControlError(message: "仅允许屏蔽内置键盘。") }
        if let helper {
            guard helper.active else { throw KeyboardControlError(message: helper.message) }
            return
        }
        guard device.builtIn, let handle = handles[device.id], !IOHIDDeviceConformsTo(handle, 1, 2) else {
            throw KeyboardControlError(message: "未找到可单独屏蔽的内置键盘，未屏蔽任何设备。")
        }
        if seized[device.id] != nil { return }
        guard geteuid() == 0 || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardControlError(message: "屏蔽未生效：请授予方寸输入监控权限，再点击重新检测。")
        }
        let status = IOHIDDeviceOpen(handle, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard status == kIOReturnSuccess else {
            let reason = status == kIOReturnExclusiveAccess ? "键盘被其他程序占用，请停用其他键盘工具" : status == kIOReturnNotPrivileged ? "系统要求管理员辅助服务权限" : "macOS 拒绝独占访问，请检查输入监控权限"
            throw KeyboardControlError(message: "屏蔽未生效：\(reason)（\(String(format: "0x%08x", status))）。")
        }
        seized[device.id] = handle
    }
    func unblock(_ device: KeyboardDevice) {
        helper?.disconnect()
        if let handle = seized.removeValue(forKey: device.id) { IOHIDDeviceClose(handle, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
    }
}

@MainActor
final class KeyboardManager {
    let controller: KeyboardController
    private var nativeBackend: NativeKeyboardBackend?
    private var pauseReasons: Set<String> = []
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    init(backend: KeyboardBackend? = nil, defaults: UserDefaults = .standard) {
        let selected = backend ?? NativeKeyboardBackend()
        controller = KeyboardController(backend: selected, defaults: defaults)
        nativeBackend = selected as? NativeKeyboardBackend
        nativeBackend?.onDevicesChanged = { [weak self] in self?.controller.refresh() }
        nativeBackend?.onHelperChanged = { [weak self] in self?.controller.refresh(retry: true) }
    }
    func start() {
        guard timer == nil else { return }
        controller.setEnabled(ToolFeature.keyboard.isEnabled())
        // Low-cost inventory reconciliation; no keystroke collection or per-key work.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.refresh() }
        }
        timer?.tolerance = 0.5
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, paused: true, reason: "sleep")
        observe(workspace, NSWorkspace.didWakeNotification, paused: false, reason: "sleep")
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, paused: true, reason: "session")
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, paused: false, reason: "session")
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked"), paused: true, reason: "lock")
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsUnlocked"), paused: false, reason: "lock")
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, paused: Bool, reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if paused { self.pauseReasons.insert(reason) } else { self.pauseReasons.remove(reason) }
                self.controller.setPaused(!self.pauseReasons.isEmpty)
            }
        }
        observers.append((center, token))
    }
    func stop() {
        timer?.invalidate(); timer = nil
        controller.stop()
        for (center, observer) in observers { center.removeObserver(observer) }; observers = []
    }
}
