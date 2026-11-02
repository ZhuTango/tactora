import AppKit

@main struct KeyboardUIChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var registrationEvents: [String] = []
        try await refreshKeyboardHelperRegistration(previous: "82", current: "84", unregister: {
            registrationEvents.append("unregister")
        }, register: { registrationEvents.append("register") }, save: { registrationEvents.append("save") })
        precondition(registrationEvents == ["unregister", "register", "save"])
        registrationEvents = []
        try await refreshKeyboardHelperRegistration(previous: "84", current: "84", unregister: {
            registrationEvents.append("unregister")
        }, register: { registrationEvents.append("register") }, save: { registrationEvents.append("save") })
        precondition(registrationEvents.isEmpty)
        do {
            try await refreshKeyboardHelperRegistration(previous: nil, current: "84", unregister: {}, register: {
                throw KeyboardControlError(message: "denied")
            }, save: { registrationEvents.append("save") })
            preconditionFailure("failed registration must propagate")
        } catch { precondition(registrationEvents.isEmpty) }
        print("PASS: helper upgrade unregister/register/save order, same-build no-op and failed registration not persisted")
        if CommandLine.arguments.contains("--native") {
            let backend = NativeKeyboardBackend()
            let devices = try backend.devices()
            precondition(devices.contains(where: \.builtIn))
            precondition(!devices.contains { $0.name.contains("Virtual") || $0.name.contains("G604") })
            for device in devices { print("DEVICE", device.name, device.transport, device.builtIn) }
            if CommandLine.arguments.contains("--mapping") {
                // F20 -> F19 only, immediately restored. No common typing key is affected.
                for device in devices {
                    let before = try backend.mappings(for: device)
                    let probe = KeyboardMapping(source: 0x70000006f, destination: 0x70000006e)
                    defer { try? backend.setMappings(before, for: device) }
                    try backend.setMappings(before.filter { $0.source != probe.source } + [probe], for: device)
                    let readback = try backend.mappings(for: device)
                    precondition(readback.contains(probe))
                    try backend.setMappings(before, for: device)
                    print("PASS native mapping readback and restoration:", device.name)
                }
            }
            return
        }
        let suite = "tactora.keyboard.ui.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeKeyboardBackend()
        let internalDevice = KeyboardDevice(id: "internal", name: "Apple Internal Keyboard", transport: "SPI", builtIn: true, connectionID: 1)
        let external = KeyboardDevice(id: "external", name: "Bluetooth Keyboard", transport: "Bluetooth", builtIn: false, connectionID: 2)
        backend.inventory = [internalDevice, external]
        let manager = KeyboardManager(backend: backend, defaults: defaults)
        manager.controller.setEnabled(true)
        let view = KeyboardSettingsView(controller: manager.controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 788, height: 604), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let picker = descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "keyboard.device" }!
        let shield = descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "keyboard.disableBuiltIn" }!
        precondition(!shield.isEnabled)
        picker.selectItem(at: 1); NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        precondition(shield.isEnabled)
        shield.performClick(nil)
        precondition(manager.controller.profile(for: external).disableBuiltIn && backend.blocks == [internalDevice.id])
        let swap = descendants(view).compactMap { $0 as? NSButton }.first { $0.title.contains("交换") || $0.title.contains("Swap") }!
        swap.performClick(nil)
        precondition(manager.controller.profile(for: external).mappings.count == 2)
        window.contentView?.layoutSubtreeIfNeeded()
        let status = descendants(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "keyboard.status" }!
        let statusFrame = view.convert(status.bounds, from: status)
        print("LAYOUT", view.bounds, statusFrame)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/keyboard-settings.png"))
        }
        precondition(view.bounds.contains(statusFrame), "status must fit the settings viewport")
        let restore = descendants(view).compactMap { $0 as? NSButton }.first { $0.title.contains("恢复所有") || $0.title.contains("Restore all") }!
        restore.performClick(nil)
        precondition(backend.blocks.isEmpty && !ToolFeature.keyboard.isEnabled(in: defaults))
        print("PASS: keyboard device selection, built-in protection eligibility, swap mappings, layout bounds and emergency restore")
    }
}
