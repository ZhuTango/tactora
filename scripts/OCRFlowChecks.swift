import AppKit

@main struct OCRFlowChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await checks() } catch { fatalError(error.localizedDescription) }
            app.terminate(nil)
        }
        app.run()
    }
    @MainActor static func checks() async throws {
        let suite = "ocr-flow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let board = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = ClipboardStore(url: root.appendingPathComponent("history.json"), pasteboard: board)
        let manager = OCRManager(store: store, defaults: defaults)
        defer { manager.stop(); store.stop() }
        let image = URL(fileURLWithPath: ".build/ocr-fixture.png")
        func settle() async throws {
            for _ in 0..<600 {
                if !manager.busy { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            preconditionFailure("OCR did not finish")
        }
        var shows = 0
        manager.onShowHistory = { shows += 1 }
        manager.showHistory = true
        manager.recognizeImage(at: image)
        try await settle()
        precondition(board.string(forType: .string)?.contains("Tactora OCR 2026") == true)
        precondition(store.entries.isEmpty && shows == 0)
        try store.setEnabled(true); store.stop()
        manager.recognizeImage(at: image)
        try await settle()
        precondition(store.entries.first?.origin == "ocr" && shows == 1)
        board.clearContents(); board.setString("must remain", forType: .string)
        manager.recognizeImage(at: image)
        ToolFeature.ocr.setEnabled(false, in: defaults); manager.refreshEnabled()
        try await settle()
        precondition(board.string(forType: .string) == "must remain", "Disabling cancels delivery")
        manager.recognizeImage(at: image)
        precondition(!manager.busy && board.string(forType: .string) == "must remain")
        print("PASS: real OCR async delivery, independent clipboard opt-in, optional opening and disable cancellation")
    }
}
