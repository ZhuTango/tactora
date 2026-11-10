import AppKit
import AVKit
import ImageIO

@MainActor
private final class RecordingResultImageView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

@MainActor
final class ScreenshotRecordingResultView: NSView {
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?
    private let playerView = AVPlayerView()
    private let imageView = RecordingResultImageView()
    private let message = NSTextField(wrappingLabelWithString: "预览确认后保存到文件。")
    private let saveButton = NSButton(title: "保存…", target: nil, action: nil)
    private let revealButton = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
    private let playButton = NSButton(title: "暂停预览", target: nil, action: nil)
    private var playing = true
    let metadata: String

    init(url: URL, isGIF: Bool) {
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        var dimensions = ""
        var duration: Double = 0
        if isGIF, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            dimensions = "\(properties?[kCGImagePropertyPixelWidth as String] as? Int ?? 0) × \(properties?[kCGImagePropertyPixelHeight as String] as? Int ?? 0)"
            for index in 0..<CGImageSourceGetCount(source) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                duration += gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0
            }
        } else {
            let asset = AVURLAsset(url: url)
            duration = CMTimeGetSeconds(asset.duration)
            if let track = asset.tracks(withMediaType: .video).first {
                let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
                dimensions = "\(Int(abs(rect.width))) × \(Int(abs(rect.height)))"
            }
        }
        metadata = "\(isGIF ? "GIF" : "MP4")  ·  \(dimensions)  ·  \(String(format: "%.1f 秒", duration.isFinite ? duration : 0))  ·  \(size)"
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: isGIF ? "GIF 已生成" : "录制完成")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let details = NSTextField(labelWithString: metadata)
        details.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        details.textColor = .secondaryLabelColor
        details.identifier = NSUserInterfaceItemIdentifier("recording.result.metadata")
        let header = NSStackView(views: [heading, details])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        let stage = NSView()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        stage.layer?.cornerRadius = 10
        stage.layer?.masksToBounds = true
        stage.identifier = NSUserInterfaceItemIdentifier("recording.result.preview")
        let preview: NSView
        if isGIF {
            imageView.image = NSImage(contentsOf: url)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            playing = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            imageView.animates = playing
            playButton.title = playing ? "暂停预览" : "播放预览"
            imageView.setAccessibilityLabel("GIF 动画预览")
            preview = imageView
        } else {
            playerView.player = AVPlayer(url: url)
            playerView.controlsStyle = .inline
            playerView.videoGravity = .resizeAspect
            playerView.setAccessibilityLabel("视频预览")
            preview = playerView
        }
        stage.addSubview(preview)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: stage.topAnchor, constant: 8),
            preview.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -8)
        ])
        message.setContentHuggingPriority(.required, for: .vertical)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.identifier = NSUserInterfaceItemIdentifier("recording.result.status")
        let close = NSButton(title: "关闭", target: self, action: #selector(closeResult))
        close.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.identifier = NSUserInterfaceItemIdentifier("recording.result.save")
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.isHidden = true
        let left = NSStackView(views: [close, revealButton])
        left.spacing = 8
        if isGIF {
            playButton.target = self
            playButton.action = #selector(togglePlayback)
            left.addArrangedSubview(playButton)
        }
        let right = NSStackView()
        right.spacing = 8
        if isGIF {
            let copy = NSButton(title: "复制 GIF", target: self, action: #selector(copyGIF))
            copy.identifier = NSUserInterfaceItemIdentifier("recording.result.copy")
            right.addArrangedSubview(copy)
        }
        right.addArrangedSubview(saveButton)
        for view in [header, stage, message, left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 48),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stage.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stage.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: right.topAnchor, constant: -12),
            left.heightAnchor.constraint(equalToConstant: 32),
            right.heightAnchor.constraint(equalToConstant: 32),
            left.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            left.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            right.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func showSaved(_ url: URL) {
        message.stringValue = "已保存 · \(url.lastPathComponent)"
        message.toolTip = url.path
        revealButton.isHidden = false
        saveButton.title = "另存为…"
    }
    func showStatus(_ text: String) { message.stringValue = text }
    func stopPlayback() { playerView.player?.pause(); playerView.player = nil; imageView.animates = false }
    @objc private func togglePlayback() {
        playing.toggle()
        imageView.animates = playing
        playButton.title = playing ? "暂停预览" : "播放预览"
    }
    @objc private func save() { onSave?() }
    @objc private func copyGIF() { onCopy?() }
    @objc private func reveal() { onReveal?() }
    @objc private func closeResult() { onClose?() }
}
