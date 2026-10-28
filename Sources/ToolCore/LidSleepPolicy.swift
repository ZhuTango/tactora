import Foundation

struct LidSleepPolicy {
    static let preferenceKey = "sleepDisplaysOnLidClose"
    private var wasActive = false

    // Global display sleep is safe only when every online display is built in.
    static func canSleepDisplays(onlineDisplaysBuiltIn: [Bool]?) -> Bool {
        guard let displays = onlineDisplaysBuiltIn, !displays.isEmpty else { return false }
        return displays.allSatisfy { $0 }
    }

    mutating func update(enabled: Bool, closed: Bool?) -> Bool {
        let active = enabled && closed == true
        defer { wasActive = active }
        return active && !wasActive
    }
}
