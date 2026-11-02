import Foundation

@MainActor final class FakeKeyboardBackend: KeyboardBackend {
    var inventory: [KeyboardDevice] = []
    var maps: [String: [KeyboardMapping]] = [:]
    var blocks: Set<String> = []
    var failDiscovery = false
    var failBlock = false
    var writes = 0
    var protectionTriggers: [KeyboardDevice] = []
    func prepareProtection(_ externals: [KeyboardDevice]) { protectionTriggers = externals }
    func devices() throws -> [KeyboardDevice] {
        if failDiscovery { throw KeyboardControlError(message: "discovery failed") }; return inventory
    }
    func mappings(for device: KeyboardDevice) throws -> [KeyboardMapping] { maps[device.id] ?? [] }
    func setMappings(_ value: [KeyboardMapping], for device: KeyboardDevice) throws { maps[device.id] = value; writes += 1 }
    func block(_ device: KeyboardDevice) throws {
        if failBlock { throw KeyboardControlError(message: "occupied") }; blocks.insert(device.id)
    }
    func unblock(_ device: KeyboardDevice) { blocks.remove(device.id) }
}
