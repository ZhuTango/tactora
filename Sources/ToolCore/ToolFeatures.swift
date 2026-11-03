import Foundation

// Existing tools default on; hardware fan control requires explicit opt-in.
enum ToolFeature: String, CaseIterable {
    case clipboard, wallpaper, apps, windows, awake, ocr, text, keyboard, calendar, fans
    func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "toolEnabled." + rawValue) as? Bool ?? (self != .fans)
    }
    func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "toolEnabled." + rawValue)
    }
}
