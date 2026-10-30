import AppKit
@MainActor final class Receiver: NSObject {
 var calls = 0
 @objc func openSettings(_ sender: Any?) { calls += 1 }
}
@main struct Checks {
 @MainActor static func main() {
  _ = NSApplication.shared
  let menu = ToolStatusMenu(); menu.autoenablesItems = false
  menu.addItem(.separator()); menu.addItem(.separator())
  let receiver = Receiver()
  let item = NSMenuItem(title: "窗口管理…", action: #selector(Receiver.openSettings(_:)), keyEquivalent: "m")
  item.target = receiver
  item.identifier = ToolStatusMenu.shortcutHintIdentifier
  item.keyEquivalentModifierMask = [.control, .option, .command]
  menu.addItem(item); menu.addItem(.separator()); menu.addItem(.separator())
  let settings = NSMenuItem(title: "设置…", action: nil, keyEquivalent: ",")
  menu.addItem(settings); menu.addItem(.separator())
  ToolStatusMenu.removeEmptySeparators(from: menu)
  precondition(menu.items.count == 3 && menu.items[1].isSeparatorItem)
  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .command], timestamp: 0, windowNumber: 0, context: nil, characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46)!
  precondition(!menu.performKeyEquivalent(with: event))
  precondition(receiver.calls == 0)
  precondition(item.keyEquivalent == "m" && item.keyEquivalentModifierMask == [.control, .option, .command])
  let empty = NSMenu(); empty.addItem(.separator()); empty.addItem(.separator())
  ToolStatusMenu.removeEmptySeparators(from: empty); precondition(empty.items.isEmpty)
  print("PASS: grouped separators, empty groups, shortcut display restoration and no settings hotkey interception")
 }
}
