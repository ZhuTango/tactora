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
    private let resetButton = NSButton(title: "重新开始", target: nil, action: nil)
    private let previewScroll = NSScrollView()
    private var lastProcessedImage: CGImage?
    private var pendingFinish = false
    private var finalScrollImage: CGImage?
    private var scrollReadyToFinish = false
    private var scrollGeneration = UUID()
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
        let previewHeight = min(160, max(72, 308 * region.height / max(1, region.width)))
        let contentSize = NSSize(width: mode == .scroll ? 340 : 302, height: mode == .scroll ? previewHeight + 122 : 56)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = mode == .scroll ? "滚动截图" : (mode == .gif ? "GIF · 无音频" : "视频 · 无音频")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        let root = NSView()
        panel.contentView = root
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.startAnimation(nil)
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let statusRow = NSStackView(views: [progress, status])
        statusRow.spacing = 6
        statusRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for button in [resetButton, finishButton, cancelButton] { button.target = self }
        resetButton.action = #selector(resetScroll)
        resetButton.toolTip = "清空拼接结果，从当前画面重新开始"
        finishButton.action = #selector(finish)
        if mode == .scroll { finishButton.keyEquivalent = "\r" }
        finishButton.title = mode == .scroll ? "完成" : "停止"
        finishButton.bezelStyle = .rounded
        finishButton.bezelColor = .controlAccentColor
        finishButton.image = NSImage(systemSymbolName: mode == .scroll ? "checkmark" : "stop.fill", accessibilityDescription: nil)
        finishButton.imagePosition = .imageLeading
        finishButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let stack = NSStackView()
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        if mode == .scroll {
            stack.orientation = .vertical
            stack.alignment = .leading
            status.widthAnchor.constraint(equalToConstant: 286).isActive = true
            stack.addArrangedSubview(statusRow)
            let hint = NSTextField(labelWithString: "在内容区域缓慢向下滚动，自动拼接")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.toolTip = "保持窗口与选区位置不变。可滚动预览检查接缝，不满意时重新开始。固定页眉和动画请留在选区外。"
            hint.heightAnchor.constraint(equalToConstant: 16).isActive = true
            stack.addArrangedSubview(hint)
            preview.imageScaling = .scaleAxesIndependently
            previewScroll.documentView = preview
            previewScroll.hasVerticalScroller = true
            previewScroll.autohidesScrollers = true
            previewScroll.borderType = .bezelBorder
            previewScroll.setAccessibilityLabel("长截图实时预览")
            previewScroll.widthAnchor.constraint(equalToConstant: 308).isActive = true
            previewScroll.heightAnchor.constraint(equalToConstant: previewHeight).isActive = true
            stack.addArrangedSubview(previewScroll)
            let spacer = NSView()
            let actions = NSStackView(views: [spacer, resetButton, finishButton])
            actions.spacing = 8
            actions.widthAnchor.constraint(equalToConstant: 308).isActive = true
            actions.heightAnchor.constraint(equalToConstant: 30).isActive = true
            stack.addArrangedSubview(actions)
        } else {
            status.widthAnchor.constraint(equalToConstant: 160).isActive = true
            stack.addArrangedSubview(statusRow)
            stack.addArrangedSubview(finishButton)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        panel.setContentSize(contentSize)
        resetButton.isEnabled = false
        finishButton.isEnabled = false
        let area = screen.visibleFrame
        let capture = NSRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
        var x = area.maxX - panel.frame.width - 12
        if mode == .scroll {
            if capture.maxX + 12 + panel.frame.width <= area.maxX { x = capture.maxX + 12 }
            else if capture.minX - 12 - panel.frame.width >= area.minX { x = capture.minX - 12 - panel.frame.width }
        }
        panel.setFrameTopLeftPoint(NSPoint(x: max(area.minX, x), y: min(area.maxY, max(area.minY + panel.frame.height, capture.maxY))))
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
                resetButton.isEnabled = true
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
                else { status.stringValue = error.localizedDescription; status.toolTip = error.localizedDescription; ending = true }
            }
        }
    }
    private func tick() {
        guard !ending else { return }
        if let error = engine.error { status.stringValue = error.localizedDescription; finish(); return }
        if mode == .scroll {
            appendFrame()
        } else {
            let seconds = Int(Date().timeIntervalSince(startTime))
            let limit = mode == .gif ? 60 : 1800
            status.stringValue = String(format: "● %02d:%02d", seconds / 60, seconds % 60)
            status.toolTip = "\(fps) fps · 上限 \(mode == .gif ? "60 秒" : "30 分钟") · 无音频"
            if seconds >= limit { finish() }
        }
    }
    @objc private func resetScroll() {
        guard mode == .scroll, !ending, !pendingFinish else { return }
        scrollGeneration = UUID()
        stitcher = ScreenshotScrollStitcher()
        lastProcessedImage = nil
        preview.image = nil
        finishButton.isEnabled = false
        status.stringValue = "正在获取当前画面…"
        // The in-flight task will discard its old result and then capture this generation.
        if !appending { appendFrame() }
    }
    private func appendFrame(image suppliedImage: CGImage? = nil) {
        guard !ending, !appending, let image = suppliedImage ?? engine.snapshot, image !== lastProcessedImage else { return }
        lastProcessedImage = image
        appending = true
        let current = stitcher
        let generation = scrollGeneration
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ScreenshotScrollStitcher, Error> in
                var next = current
                do { try next.append(image); return .success(next) }
                catch { return .failure(error) }
            }.value
            appending = false
            guard !ending, !cancelled else { return }
            guard generation == scrollGeneration else { appendFrame(); return }
            switch result {
            case .success(let next):
                stitcher = next
                if let cg = next.result {
                    preview.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    let width = max(1, previewScroll.contentSize.width)
                    preview.setFrameSize(NSSize(width: width, height: width * CGFloat(cg.height) / CGFloat(cg.width)))
                    preview.scroll(.zero)
                    status.stringValue = "自动拼接 · \(cg.width) × \(cg.height)"
                    status.toolTip = "已采集 \(next.count) 帧，可继续向下滚动或完成"
                }
            case .failure(ScreenshotScrollStitcher.StitchError.unchanged):
                break
            case .failure(ScreenshotScrollStitcher.StitchError.limit):
                status.stringValue = "已达长度上限，请完成或重新开始"
            case .failure:
                status.stringValue = "暂未接上，请慢滚或回滚一点"
                status.toolTip = "已有结果已保留。请回到上次采集位置再慢慢向下滚动，或重新开始。固定页眉和动态内容可能影响拼接。"
            }
            finishButton.isEnabled = stitcher.count > 0 && !pendingFinish
            if pendingFinish { finish() }
        }
    }
    @objc private func finish() {
        if encodedURL != nil { saveRecording(); return }
        guard !preparing, !ending else { return }
        if mode == .scroll && !scrollReadyToFinish {
            if !pendingFinish {
                finalScrollImage = engine.snapshot
                finishButton.isEnabled = false
                resetButton.isEnabled = false
                status.stringValue = "正在完成最后一帧…"
            }
            pendingFinish = true
            if appending { return }
            appendFrame(image: finalScrollImage)
            if appending { return }
            scrollReadyToFinish = true
        }
        ending = true
        finishing = true
        timer?.invalidate(); timer = nil
        resetButton.isEnabled = false
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
                status.toolTip = error.localizedDescription
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
