import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotSession: NSWindowController, NSWindowDelegate {
    enum Mode { case scroll, video, gif }
    private let mode: Mode
    private let screen: NSScreen
    private let region: CGRect
    private let engine: ScreenshotStream
    private let fps: Int
    private let directory: URL
    private var stitcher = ScreenshotScrollStitcher()
    private let status = NSTextField(wrappingLabelWithString: "正在准备…")
    private let preview = NSImageView()
    private let appendButton = NSButton(title: "添加当前画面", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var border: NSPanel?
    private var finishing = false
    private var timer: Timer?
    private var startTime = Date()
    private var appending = false
    private var preparing = true
    private var ending = false
    private var cancelled = false
    private var completed = false
    private var encodedURL: URL?
    private var savedURL: URL?
    private var copiedResult = false
    private var resultView: ScreenshotRecordingResultView?
    private let progress = NSProgressIndicator()
    var onImage: ((NSImage) -> Void)?
    var onClose: (() -> Void)?

    init(mode: Mode, screen: NSScreen, region: CGRect, fps: Int) throws {
        self.mode = mode
        self.screen = screen
        self.region = region
        self.fps = fps
        engine = ScreenshotStream(framesPerSecond: mode == .scroll ? 5 : fps)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tactora-recording-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: mode == .scroll ? 340 : 140), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = mode == .scroll ? "滚动截图" : (mode == .gif ? "录制 GIF · 无音频" : "录制视频 · 无音频")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        panel.contentView = root
        status.widthAnchor.constraint(equalToConstant: 320).isActive = true
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.startAnimation(nil)
        let statusRow = NSStackView(views: [progress, status])
        statusRow.spacing = 8
        root.addArrangedSubview(statusRow)
        if mode == .scroll {
            let hint = NSTextField(wrappingLabelWithString: "在原窗口向下滚动半屏，停稳后点击“添加当前画面”。选区应避开固定页眉和动画。")
            hint.textColor = .secondaryLabelColor
            hint.widthAnchor.constraint(equalToConstant: 344).isActive = true
            root.addArrangedSubview(hint)
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.widthAnchor.constraint(equalToConstant: 344).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 140).isActive = true
            root.addArrangedSubview(preview)
        }
        for button in [appendButton, finishButton, cancelButton] { button.target = self }
        appendButton.action = #selector(appendFrame)
        finishButton.action = #selector(finish)
        finishButton.title = mode == .scroll ? "完成拼接" : "结束录制"
        finishButton.bezelStyle = .rounded
        finishButton.bezelColor = .controlAccentColor
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        root.addArrangedSubview(NSStackView(views: mode == .scroll ? [appendButton, cancelButton, finishButton] : [cancelButton, finishButton]))
        appendButton.isEnabled = false
        finishButton.isEnabled = false
        let area = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: max(area.minX, area.maxX - 400), y: area.maxY - 20))
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func start() {
        showWindow(nil)
        let frame = NSRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
        let border = NSPanel(contentRect: frame.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.hidesOnDeactivate = false
        border.isReleasedWhenClosed = false
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView?.wantsLayer = true
        border.contentView?.layer?.borderWidth = 2
        border.contentView?.layer?.borderColor = (mode == .scroll ? NSColor.systemBlue : NSColor.systemRed).cgColor
        border.orderFront(nil)
        self.border = border
        Task { [self] in
            do {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
                    throw ScreenshotStream.encodingError("无法找到目标屏幕")
                }
                try await engine.start(displayID: id, rect: region, scale: screen.backingScaleFactor,
                                       movieURL: mode == .scroll ? nil : directory.appendingPathComponent("recording.mp4"))
                preparing = false
                progress.stopAnimation(nil)
                if cancelled { try? await engine.stop(cancel: true); cleanup(); return }
                startTime = Date()
                appendButton.isEnabled = true
                finishButton.isEnabled = mode != .scroll
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
                tick()
            } catch {
                preparing = false
                progress.stopAnimation(nil)
                if cancelled { cleanup() }
                else { status.stringValue = error.localizedDescription; ending = true }
            }
        }
    }
    private func tick() {
        guard !ending else { return }
        if let error = engine.error { status.stringValue = error.localizedDescription; finish(); return }
        if mode == .scroll {
            if stitcher.count == 0, engine.snapshot != nil { appendFrame() }
        } else {
            let seconds = Int(Date().timeIntervalSince(startTime))
            let limit = mode == .gif ? 60 : 1800
            status.stringValue = String(format: "● %02d:%02d  ·  %d fps  ·  上限 %@", seconds / 60, seconds % 60, fps, mode == .gif ? "60 秒" : "30 分钟")
            if seconds >= limit { finish() }
        }
    }
    @objc private func appendFrame() {
        guard !ending, !appending, let image = engine.snapshot else { return }
        appending = true
        finishButton.isEnabled = false
        appendButton.isEnabled = false
        let current = stitcher
        Task { [self] in
            // Matching runs off the main thread so the recording controls stay responsive.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ScreenshotScrollStitcher, Error> in
                var next = current
                do { try next.append(image); return .success(next) }
                catch { return .failure(error) }
            }.value
            guard !ending, !cancelled else { return }
            appending = false
            finishButton.isEnabled = stitcher.count > 0
            switch result {
            case .success(let next):
                stitcher = next
                if let cg = next.result {
                    preview.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    status.stringValue = "已拼接 \(next.count) 帧 · \(cg.width) × \(cg.height)"
                    finishButton.isEnabled = true
                }
            case .failure(let error): status.stringValue = error.localizedDescription
            }
            appendButton.isEnabled = true
        }
    }
    @objc private func finish() {
        if encodedURL != nil { saveRecording(); return }
        guard !preparing, !ending else { return }
        ending = true
        finishing = true
        timer?.invalidate(); timer = nil
        appendButton.isEnabled = false
        finishButton.isEnabled = false
        cancelButton.isEnabled = false
        progress.startAnimation(nil)
        border?.close(); border = nil
        status.stringValue = mode == .gif ? "正在生成 GIF…" : "正在完成…"
        Task { [self] in
            do {
                try await engine.stop(cancel: false)
                if cancelled { finishing = false; cleanup(); return }
                if mode == .scroll {
                    guard let cg = stitcher.result else { throw ScreenshotStream.encodingError("尚未获取画面") }
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    let callback = onImage
                    cleanup()
                    callback?(image)
                    return
                }
                var url = directory.appendingPathComponent("recording.mp4")
                if mode == .gif {
                    let movie = url
                    let gif = directory.appendingPathComponent("recording.gif")
                    let fps = fps
                    try await Task.detached(priority: .userInitiated) { try ScreenshotStream.makeGIF(movie: movie, destination: gif, fps: fps) }.value
                    url = gif
                }
                finishing = false
                if cancelled { cleanup(); return }
                showRecordingResult(url)
            } catch {
                finishing = false
                progress.stopAnimation(nil)
                if cancelled { cleanup(); return }
                status.stringValue = error.localizedDescription
                cancelButton.isEnabled = true
            }
        }
    }
    func showRecordingResult(_ url: URL) {
        encodedURL = url
        preparing = false
        ending = true
        progress.stopAnimation(nil)
        guard let window else { return }
        let view = ScreenshotRecordingResultView(url: url, isGIF: mode == .gif)
        resultView = view
        view.onSave = { [weak self] in self?.saveRecording() }
        view.onCopy = { [weak self] in self?.copyGIF() }
        view.onReveal = { [weak self] in
            if let url = self?.savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        view.onClose = { [weak self] in self?.requestClose() }
        let area = (window.screen ?? screen).visibleFrame
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 680, height: 420)
        window.title = mode == .gif ? "GIF 预览" : "视频预览"
        window.contentView = view
        window.setContentSize(NSSize(width: min(740, area.width - 40), height: min(540, area.height - 60)))
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        window.makeKeyAndOrderFront(nil)
    }
    private func copyGIF() {
        guard mode == .gif, let url = encodedURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) else {
                throw ScreenshotStream.encodingError("复制失败，请重试")
            }
            copiedResult = true
            resultView?.showStatus("已复制 GIF，可粘贴到支持动图的应用。")
        } catch { resultView?.showStatus(error.localizedDescription) }
    }
    private func requestClose() {
        guard encodedURL != nil, savedURL == nil, !copiedResult, let window else { cancel(); return }
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "关闭未保存的录制？"
        alert.informativeText = "保存或复制后即可保留这次录制。"
        alert.addButton(withTitle: "继续预览")
        alert.addButton(withTitle: "丢弃")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.cancel() }
        }
    }
    private func saveRecording() {
        guard let window, let url = encodedURL, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [mode == .gif ? .gif : .mpeg4Movie]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Tactora-\(formatter.string(from: Date())).\(url.pathExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            do {
                // An atomic write preserves an existing destination if exporting fails.
                try Data(contentsOf: url, options: .mappedIfSafe).write(to: destination, options: .atomic)
                self.savedURL = destination
                self.resultView?.showSaved(destination)
            } catch { self.resultView?.showStatus("保存失败，可重试。\(error.localizedDescription)") }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    @objc func cancel() {
        guard !completed, !cancelled else { return }
        cancelled = true
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
        border?.orderOut(nil)
        guard !preparing, !finishing else { return }
        Task { [self] in
            if !ending { ending = true; try? await engine.stop(cancel: true) }
            cleanup()
        }
    }
    private func cleanup() {
        guard !completed else { return }
        completed = true
        resultView?.stopPlayback()
        timer?.invalidate(); timer = nil
        border?.close(); border = nil
        window?.close()
        try? FileManager.default.removeItem(at: directory)
        onClose?()
    }
}
