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
    private(set) var scrollPreview: ScreenshotScrollPreview?
    private let resetButton = ScreenshotToolButton(title: "重新开始", target: nil, action: nil)
    private var lastProcessedImage: CGImage?
    private var pendingPreviewImage: CGImage?
    private var lastPreviewTime: TimeInterval = 0
    private var pendingFinish = false
    private var finalScrollFrames: [CGImage] = []
    private var scrollReadyToFinish = false
    private var scrollGeneration = UUID()
    private let finishButton = ScreenshotToolButton(title: "完成", target: nil, action: nil)
    private let cancelButton = ScreenshotToolButton(title: "取消", target: nil, action: nil)
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
        engine = ScreenshotStream(framesPerSecond: mode == .scroll ? 30 : fps)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tactora-recording-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contentSize = NSSize(width: mode == .scroll ? 320 : 302, height: mode == .scroll ? 44 : 56)
        let mask: NSWindow.StyleMask = mode == .scroll ? [.borderless, .nonactivatingPanel] : [.titled, .closable, .utilityWindow]
        let panel = ScreenshotSessionPanel(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: mask, backing: .buffered, defer: false)
        panel.title = mode == .scroll ? "滚动截图" : (mode == .gif ? "GIF · 无音频" : "视频 · 无音频")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        let root: NSView
        if mode == .scroll {
            let card = ScreenshotToolbarView()
            card.material = .popover
            card.blendingMode = .behindWindow
            card.state = .active
            card.wantsLayer = true
            card.layer?.cornerRadius = 10
            card.layer?.masksToBounds = true
            root = card
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.onCancel = { [weak self] in self?.cancel() }
        } else { root = NSView() }
        panel.contentView = root
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.startAnimation(nil)
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let direction = NSImageView(image: NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "上下滚动自动拼接")!)
        direction.contentTintColor = .controlAccentColor
        direction.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let statusRow = NSStackView(views: [mode == .scroll ? direction : progress, status])
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
        if mode != .scroll { finishButton.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let stack = NSStackView()
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        if mode == .scroll {
            status.maximumNumberOfLines = 1
            status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            status.widthAnchor.constraint(equalToConstant: 154).isActive = true
            status.stringValue = "准备滚动截图…"
            status.setAccessibilityLabel("滚动截图状态")
            stack.addArrangedSubview(statusRow)
            let divider = NSBox()
            divider.boxType = .separator
            divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
            stack.addArrangedSubview(divider)
            for (button, symbol, label) in [(resetButton, "arrow.counterclockwise", "重新开始"),
                                            (cancelButton, "xmark", "取消 · Esc"),
                                            (finishButton, "checkmark", "完成并编辑 · Return")] {
                button.title = ""
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                button.imagePosition = .imageOnly
                button.isBordered = false
                button.bezelStyle = .regularSquare
                button.wantsLayer = true
                button.layer?.cornerRadius = 6
                button.toolTip = label
                button.setAccessibilityLabel(label)
                button.identifier = NSUserInterfaceItemIdentifier("scroll." + symbol)
                button.widthAnchor.constraint(equalToConstant: 30).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
                stack.addArrangedSubview(button)
            }
            finishButton.contentTintColor = .controlAccentColor
            scrollPreview = ScreenshotScrollPreview()
        } else {
            status.widthAnchor.constraint(equalToConstant: 160).isActive = true
            stack.addArrangedSubview(statusRow)
            stack.addArrangedSubview(finishButton)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: mode == .scroll ? 8 : 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: mode == .scroll ? -8 : -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: mode == .scroll ? 7 : 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: mode == .scroll ? -7 : -12)
        ])
        panel.setContentSize(contentSize)
        resetButton.isEnabled = false
        finishButton.isEnabled = false
        let area = screen.visibleFrame
        let capture = NSRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
        if mode == .scroll {
            panel.setFrame(ScreenshotScrollPlacement.toolbar(size: contentSize, capture: capture, area: area), display: false)
        } else {
            let x = max(area.minX, area.maxX - panel.frame.width - 12)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(area.maxY, max(area.minY + panel.frame.height, capture.maxY))))
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func start() {
        if mode == .scroll { window?.orderFront(nil) }
        else { showWindow(nil) }
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
                let timer = Timer(timeInterval: mode == .scroll ? 1.0 / 30 : 0.25, repeats: true) { [weak self] _ in
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
    func updateScrollPreview(_ image: CGImage) {
        guard mode == .scroll, let window else { return }
        let capture = NSRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
                             width: region.width, height: region.height)
        scrollPreview?.update(image, capture: capture, area: screen.visibleFrame, toolbar: window.frame)
    }

    private func refreshScrollPreview() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let image = pendingPreviewImage, now - lastPreviewTime >= 1.0 / 15 else { return }
        pendingPreviewImage = nil
        lastPreviewTime = now
        updateScrollPreview(image)
    }
    private func tick() {
        guard !ending else { return }
        if let error = engine.error { status.stringValue = error.localizedDescription; finish(); return }
        if mode == .scroll {
            refreshScrollPreview()
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
        engine.resetScrollFrames()
        scrollPreview?.clear()
        pendingPreviewImage = nil
        finishButton.isEnabled = false
        status.stringValue = "正在获取当前画面…"
        status.textColor = .labelColor
        // The in-flight task will discard its old result and then capture this generation.
        if !appending { appendFrame() }
    }
    private func appendFrame(image suppliedImage: CGImage? = nil) {
        guard !ending, !appending, let image = suppliedImage ?? engine.nextScrollFrame(), image !== lastProcessedImage else { return }
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
                    pendingPreviewImage = cg
                    refreshScrollPreview()
                    status.stringValue = "\(cg.width) × \(cg.height)"
                    status.textColor = .labelColor
                    status.toolTip = "已采集 \(next.count) 帧 · 在原内容中上下滚动，自动拼接；完成后可标注、复制或保存"
                }
            case .failure(ScreenshotScrollStitcher.StitchError.unchanged):
                break
            case .failure(ScreenshotScrollStitcher.StitchError.limit):
                status.stringValue = "已达长度上限，请完成或重新开始"
            case .failure:
                status.stringValue = "请慢滚或回滚一点"
                status.textColor = .systemOrange
                status.toolTip = "已有结果已保留。请回到上次采集位置再缓慢滚动，或重新开始。固定页眉和动态内容可能影响拼接。"
            }
            finishButton.isEnabled = stitcher.count > 0 && !pendingFinish
            if pendingFinish { finish() }
            else { appendFrame() } // Drain captured overlap immediately, not on the next UI timer tick.
        }
    }
    @objc private func finish() {
        if encodedURL != nil { saveRecording(); return }
        guard !preparing, !ending else { return }
        if mode == .scroll && !scrollReadyToFinish {
            if !pendingFinish {
                finalScrollFrames = engine.finishScrollFrames()
                finishButton.isEnabled = false
                resetButton.isEnabled = false
                status.stringValue = "正在完成最后一帧…"
            }
            pendingFinish = true
            if appending { return }
            while !finalScrollFrames.isEmpty {
                appendFrame(image: finalScrollFrames.removeFirst())
                if appending { return }
            }
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
        scrollPreview?.panel.orderOut(nil)
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
        scrollPreview?.panel.orderOut(nil)
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
        scrollPreview?.panel.close()
        window?.close()
        try? FileManager.default.removeItem(at: directory)
        onClose?()
    }
}

/// A floating control strip that can receive Escape after a deliberate click,
/// without activating Tactora when capture starts over another application's content.
@MainActor
private final class ScreenshotSessionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onCancel { onCancel() }
        else { super.keyDown(with: event) }
    }
}

/// Screen-point placement; all coordinates retain the selected display's origin.
enum ScreenshotScrollPlacement {
    static func toolbar(size: NSSize, capture: NSRect, area: NSRect) -> NSRect {
        let x = min(max(capture.maxX - size.width, area.minX + 8), area.maxX - size.width - 8)
        let y: CGFloat
        if capture.minY - size.height - 8 >= area.minY { y = capture.minY - size.height - 8 }
        else if capture.maxY + size.height + 8 <= area.maxY { y = capture.maxY + 8 }
        else { y = area.minY + 8 }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    static func preview(image: NSSize, capture: NSRect, area: NSRect, toolbar: NSRect) -> NSRect {
        let gap: CGFloat = 8
        let right = area.maxX - capture.maxX - gap * 2
        let left = capture.minX - area.minX - gap * 2
        let useRight = right >= 96
        let useLeft = !useRight && left >= 96
        let availableWidth = useRight ? right : (useLeft ? left : area.width - gap * 2)
        let maxWidth = min(180, availableWidth)
        var top = min(capture.maxY, area.maxY - gap)
        var bottom = area.minY + gap
        // A full-width selection leaves no side room. Keep the click-through
        // thumbnail inside the selection, away from the action strip.
        if !useRight && !useLeft, toolbar.maxY > bottom, toolbar.minY < top {
            if toolbar.midY < area.midY { bottom = toolbar.maxY + gap }
            else { top = min(top, toolbar.minY - gap) }
        }
        let maxHeight = max(1, min(520, top - bottom))
        let scale = min(maxWidth / max(1, image.width), maxHeight / max(1, image.height), 1)
        let size = NSSize(width: max(1, image.width * scale), height: max(1, image.height * scale))
        let x = useRight ? capture.maxX + gap : (useLeft ? capture.minX - gap - size.width : area.maxX - gap - size.width)
        return NSRect(x: x, y: max(bottom, top - size.height), width: size.width, height: size.height)
    }
}

@MainActor
final class ScreenshotScrollPreview {
    let panel: NSPanel
    private let imageView = NSImageView()
    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Scrolling over the preview must still reach the original document.
        panel.ignoresMouseEvents = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityLabel("滚动截图实时缩略图")
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        panel.contentView = imageView
    }
    func update(_ image: CGImage, capture: NSRect, area: NSRect, toolbar: NSRect) {
        let size = NSSize(width: image.width, height: image.height)
        imageView.image = NSImage(cgImage: image, size: size)
        panel.setFrame(ScreenshotScrollPlacement.preview(image: size, capture: capture, area: area, toolbar: toolbar), display: true)
        panel.orderFront(nil)
    }
    func clear() {
        imageView.image = nil
        panel.orderOut(nil)
    }
}
