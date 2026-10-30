import AppKit

/// Some settings entries describe a global action, rather than binding that key to Settings.
@MainActor
final class ToolStatusMenu: NSMenu {
    static let shortcutHintIdentifier = NSUserInterfaceItemIdentifier("global-action-hint")

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let hints = items.filter { $0.identifier == Self.shortcutHintIdentifier }
        let keys = hints.map(\.keyEquivalent)
        for item in hints { item.keyEquivalent = "" }
        defer { for (item, key) in zip(hints, keys) { item.keyEquivalent = key } }
        return super.performKeyEquivalent(with: event)
    }

    static func removeEmptySeparators(from menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}
