import Foundation

struct LidSleepPolicy {
    // Preserve the existing switch when upgrading from display sleep to blackout.
    static let preferenceKey = "sleepDisplaysOnLidClose"
    static func shouldCover(enabled: Bool, closed: Bool?, builtIn: Bool, mirrored: Bool) -> Bool {
        enabled && closed == true && builtIn && !mirrored
    }
}
