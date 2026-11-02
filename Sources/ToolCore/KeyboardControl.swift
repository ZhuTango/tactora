import Foundation

struct KeyboardMapping: Codable, Equatable {
    var source: UInt64
    var destination: UInt64
}

struct KeyboardDevice: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let transport: String
    let builtIn: Bool
    let connectionID: UInt64
}

struct KeyboardProfile: Codable, Equatable {
    var device: KeyboardDevice
    var mappings: [KeyboardMapping] = []
    var disableBuiltIn = false
}

@MainActor
protocol KeyboardBackend: AnyObject {
    func devices() throws -> [KeyboardDevice]
    func mappings(for device: KeyboardDevice) throws -> [KeyboardMapping]
    func setMappings(_ mappings: [KeyboardMapping], for device: KeyboardDevice) throws
    func prepareProtection(_ externals: [KeyboardDevice])
    func block(_ device: KeyboardDevice) throws
    func unblock(_ device: KeyboardDevice)
}

extension KeyboardBackend { func prepareProtection(_ externals: [KeyboardDevice]) {} }

struct KeyboardControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Does not consume keystrokes. Only persists device preferences and owned system-map snapshots.
@MainActor
final class KeyboardController {
    private struct Applied: Codable {
        var device: KeyboardDevice
        var original: [KeyboardMapping]
        var written: [KeyboardMapping]
    }
    private let backend: KeyboardBackend
    private let defaults: UserDefaults
    private(set) var profiles: [KeyboardProfile]
    private(set) var connected: [KeyboardDevice] = []
    private(set) var blocked: [KeyboardDevice] = []
    private(set) var errors: [String: String] = [:]
    private(set) var enabled = false
    private(set) var paused = false
    private var applied: [String: Applied]
    private var mappingFailures: [String: String] = [:]
    private var blockFailures: [String: String] = [:]
    var onChange: (() -> Void)?
    static let profilesKey = "keyboard.deviceProfiles.v1"
    private static let journalKey = "keyboard.mappingJournal.v1"
    init(backend: KeyboardBackend, defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
        profiles = defaults.data(forKey: Self.profilesKey).flatMap { try? JSONDecoder().decode([KeyboardProfile].self, from: $0) } ?? []
        applied = defaults.data(forKey: Self.journalKey).flatMap { try? JSONDecoder().decode([String: Applied].self, from: $0) } ?? [:]
    }
    func setEnabled(_ value: Bool) { enabled = value; refresh(retry: true) }
    func setPaused(_ value: Bool) { paused = value; refresh(retry: true) }
    func save(_ profile: KeyboardProfile) throws {
        guard Set(profile.mappings.map(\.source)).count == profile.mappings.count,
              profile.mappings.allSatisfy({ KeyboardKey.codes.contains($0.source) && KeyboardKey.codes.contains($0.destination) }) else {
            throw KeyboardControlError(message: "每个原按键只能映射一次，请选择有效的按键。")
        }
        var value = profile
        if value.device.builtIn { value.disableBuiltIn = false }
        if let index = profiles.firstIndex(where: { $0.device.id == value.device.id }) { profiles[index] = value }
        else { profiles.append(value) }
        persistProfiles(); refresh(retry: true)
    }
    func profile(for device: KeyboardDevice) -> KeyboardProfile {
        profiles.first { $0.device.id == device.id } ?? KeyboardProfile(device: device)
    }
    /// Emergency stop is persistent across launches. The caller also disables the tool toggle.
    func emergencyStop() { ToolFeature.keyboard.setEnabled(false, in: defaults); stop() }
    func stop() { enabled = false; refresh() }
    private func persistProfiles() { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) } }
    private func persistJournal() { if let data = try? JSONEncoder().encode(applied) { defaults.set(data, forKey: Self.journalKey); defaults.synchronize() } }
    func refresh(retry: Bool = false) {
        errors = [:]
        let previous = connected
        do { connected = try backend.devices() }
        catch {
            backend.prepareProtection([])
            // Fail open: never keep a keyboard blocked when device detection fails.
            for device in blocked { backend.unblock(device) }; blocked = []
            errors["global"] = error.localizedDescription; onChange?(); return
        }
        if retry || previous != connected { blockFailures = [:]; mappingFailures = [:] }
        let active = enabled && !paused
        // Restore only maps still owned by us; never overwrite a later change by another tool.
        for (id, record) in applied {
            guard let device = connected.first(where: { $0.id == id }) else { continue }
            let wanted = active ? profile(for: device).mappings : []
            if wanted.isEmpty || device.connectionID != record.device.connectionID {
                do {
                    if try backend.mappings(for: device) == record.written {
                        try backend.setMappings(record.original, for: device)
                    }
                    applied.removeValue(forKey: id); persistJournal()
                } catch { errors[id] = error.localizedDescription }
            }
        }
        for device in connected where active && !profile(for: device).mappings.isEmpty {
            if let failure = mappingFailures[device.id] { errors[device.id] = failure; continue }
            do {
                let current = try backend.mappings(for: device)
                if let record = applied[device.id], current != record.written {
                    errors[device.id] = "键位已被其他工具更改。请先停用本功能，再重新启用。"; continue
                }
                let original = applied[device.id]?.original ?? current
                let own = profile(for: device).mappings
                let sources = Set(own.map(\.source))
                let desired = original.filter { !sources.contains($0.source) } + own
                if current != desired {
                    // Persist rollback BEFORE touching the system, including across unexpected exits.
                    let previous = applied[device.id]
                    applied[device.id] = Applied(device: device, original: original, written: desired)
                    persistJournal()
                    do { try backend.setMappings(desired, for: device) }
                    catch {
                        if (try? backend.mappings(for: device)) == current {
                            applied[device.id] = previous; persistJournal()
                        }
                        throw error
                    }
                }
            } catch { errors[device.id] = error.localizedDescription; mappingFailures[device.id] = error.localizedDescription }
        }
        let triggers = active ? connected.filter { !$0.builtIn && profile(for: $0).disableBuiltIn } : []
        backend.prepareProtection(triggers)
        let shouldBlock = !triggers.isEmpty
        let targets = shouldBlock ? connected.filter(\.builtIn) : []
        if !shouldBlock { blockFailures = [:] }
        for device in blocked where !targets.contains(device) { backend.unblock(device) }
        blocked.removeAll { !targets.contains($0) }
        for device in targets where !blocked.contains(device) {
            if let failure = blockFailures[device.id] { errors[device.id] = failure; continue }
            do { try backend.block(device); blocked.append(device) }
            catch { errors[device.id] = error.localizedDescription; blockFailures[device.id] = error.localizedDescription }
        }
        onChange?()
    }
}

struct KeyboardKey {
    let label: String
    let usage: UInt64
    var code: UInt64 { 0x700000000 | usage }
    static let all: [KeyboardKey] = {
        var keys = [("左 ⌘ Command",224+3),("右 ⌘ Command",231),("左 ⌥ Option",226),("右 ⌥ Option",230),
                    ("左 ⌃ Control",224),("右 ⌃ Control",228),("左 ⇧ Shift",225),("右 ⇧ Shift",229),
                    ("Caps Lock",57),("Esc",41),("Tab",43),("Return",40),("Space",44),("Backspace",42),("Delete ⌦",76),
                    ("←",80),("→",79),("↑",82),("↓",81),("Home",74),("End",77),("Page Up",75),("Page Down",78)]
        keys += (0..<26).map { (String(UnicodeScalar(65+$0)!),4+$0) }
        keys += (1...9).map { (String($0),29+$0) } + [("0",39)]
        keys += (1...12).map { ("F\($0)",57+$0) }
        keys += [("-",45),("=",46),("[",47),("]",48),("\\",49),(";",51),("'",52),("`",53),(",",54),(".",55),("/",56)]
        return keys.map { KeyboardKey(label: $0.0, usage: UInt64($0.1)) }
    }()
    static let codes = Set(all.map(\.code))
}
