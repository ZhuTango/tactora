import Foundation

// Absent keys mean enabled, preserving existing installations.
enum ToolFeature: String, CaseIterable {
    case clipboard, wallpaper, apps, windows, awake
    func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "toolEnabled." + rawValue) as? Bool ?? true
    }
    func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "toolEnabled." + rawValue)
    }
}
