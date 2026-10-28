import Foundation

struct LidSleepPolicy {
    static let preferenceKey = "sleepDisplaysOnLidClose"
    private var wasActive = false

    mutating func update(enabled: Bool, closed: Bool?) -> Bool {
        let active = enabled && closed == true
        defer { wasActive = active }
        return active && !wasActive
    }
}
