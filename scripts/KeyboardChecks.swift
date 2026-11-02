import Foundation

@main struct KeyboardChecks {
    @MainActor static func main() throws {
        let suite = "tactora.keyboard.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let builtin = KeyboardDevice(id: "internal", name: "Built-in", transport: "SPI", builtIn: true, connectionID: 1)
        let external = KeyboardDevice(id: "bt-a", name: "Bluetooth A", transport: "Bluetooth", builtIn: false, connectionID: 2)
        let other = KeyboardDevice(id: "bt-b", name: "Bluetooth B", transport: "Bluetooth", builtIn: false, connectionID: 3)
        let map = KeyboardMapping(source: 0x7000000e3, destination: 0x7000000e2)
        let original = KeyboardMapping(source: 0x700000039, destination: 0x700000029)
        let backend = FakeKeyboardBackend(); backend.inventory = [builtin, external, other]; backend.maps[external.id] = [original]
        let controller = KeyboardController(backend: backend, defaults: defaults)
        controller.setEnabled(true)
        try controller.save(KeyboardProfile(device: external, mappings: [map], disableBuiltIn: true))
        precondition(backend.maps[external.id] == [original, map] && backend.maps[builtin.id] == nil && backend.maps[other.id] == nil)
        precondition(controller.blocked == [builtin] && backend.blocks == [builtin.id])
        let writeCount = backend.writes
        for _ in 0..<20 { controller.refresh() }
        precondition(backend.writes == writeCount, "idle polls must not rewrite system maps")
        backend.inventory = [builtin, other]; controller.refresh()
        precondition(backend.blocks.isEmpty, "disconnect must release built-in")
        backend.inventory = [builtin, external, other]; controller.refresh()
        precondition(backend.blocks == [builtin.id])
        controller.setPaused(true); precondition(backend.blocks.isEmpty && backend.maps[external.id] == [original])
        controller.setPaused(false); precondition(backend.blocks == [builtin.id])
        backend.failDiscovery = true; controller.refresh(); precondition(backend.blocks.isEmpty && backend.protectionTriggers.isEmpty)
        backend.failDiscovery = false; backend.failBlock = true; controller.refresh()
        precondition(controller.blocked.isEmpty && controller.errors[builtin.id] == "occupied")
        backend.failBlock = false
        controller.stop(); precondition(backend.maps[external.id] == [original])
        let reopened = KeyboardController(backend: backend, defaults: defaults)
        precondition(reopened.profile(for: external).disableBuiltIn && reopened.profile(for: external).mappings == [map])
        reopened.setEnabled(true)
        backend.maps[external.id] = [original] // an external tool took ownership
        reopened.refresh(); precondition(reopened.errors[external.id] != nil)
        reopened.stop(); precondition(backend.maps[external.id] == [original], "stop must not overwrite another tool")
        do { try reopened.save(KeyboardProfile(device: external, mappings: [map,map])); fatalError("duplicate accepted") } catch {}
        precondition(reopened.profile(for: external).mappings == [map])
        try reopened.save(KeyboardProfile(device: builtin, disableBuiltIn: true))
        precondition(!reopened.profile(for: builtin).disableBuiltIn)
        // Two selected externals: disconnecting either alone must not release protection.
        try reopened.save(KeyboardProfile(device: other, disableBuiltIn: true))
        reopened.setEnabled(true); backend.inventory = [builtin, other]; reopened.refresh()
        precondition(backend.blocks == [builtin.id])
        backend.inventory = [builtin]; reopened.refresh(); precondition(backend.blocks.isEmpty)
        reopened.stop()
        backend.inventory = [builtin, external]
        reopened.setEnabled(true)
        let afterCrash = KeyboardController(backend: backend, defaults: defaults)
        afterCrash.setEnabled(false)
        precondition(backend.maps[external.id] == [original], "journal restores owned maps after a crash")
        reopened.stop()
        print("PASS: per-device mapping, persistence, external disconnect, multiple triggers, sleep, fail-open, conflicts and rollback")
    }
}
