import AppKit
import AVFoundation
import ImageIO

enum WallpaperError: LocalizedError {
    case invalidPhoto, invalidVideo, missingFile
    var errorDescription: String? {
        switch self {
        case .invalidPhoto: return "无法读取这张照片，请选择有效的 JPEG、PNG 或 HEIC 图片。"
        case .invalidVideo: return "无法播放这个文件，请选择系统支持的视频，例如 H.264 / HEVC 编码的 MP4 或 MOV。"
        case .missingFile: return "找不到或无法读取文件，可能已经移动或删除。请重新选择。"
        }
    }
}

@MainActor
public final class WallpaperEngine {
    public private(set) var videoURL: URL?
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var windows: [NSWindow] = []
    private var posterGenerator: AVAssetImageGenerator?
    private var posterRequest = UUID()
    private var poster: CGImage?
    private var resumeTime = CMTime.zero
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var visibilityObserver: NSObjectProtocol?
    private var idleRelease: DispatchWorkItem?
    private let loopMode: VideoLoopMode
    private let idleReleaseDelay: TimeInterval
    private var automaticallyPauseWhenOccluded: Bool
    private var visibilityTimer: Timer?
    private(set) var desktopHidden = false
    private(set) var completedLoops = 0
    var onVisibilityChange: (() -> Void)?
    private var targetScreens: [NSScreen]?
    private var screens: [NSScreen] { targetScreens ?? NSScreen.screens }
    public var onFailure: ((Error) -> Void)?
    public var policy = PlaybackPolicy() {
        didSet { synchronize() }
    }

    public init(screens: [NSScreen]? = nil, loopMode: VideoLoopMode = .seamless,
                automaticallyPauseWhenOccluded: Bool = true, idleReleaseDelay: TimeInterval = 20) {
        targetScreens = screens
        self.idleReleaseDelay = idleReleaseDelay
        self.loopMode = loopMode
        self.automaticallyPauseWhenOccluded = automaticallyPauseWhenOccluded
        if automaticallyPauseWhenOccluded {
            visibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.videoURL != nil,
                          self.windows.contains(where: { $0 === window }) else { return }
                    self.updateDesktopVisibility()
                }
            }
        }
    }

    deinit {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        idleRelease?.cancel()
        visibilityTimer?.invalidate()
    }

    public var isPlaying: Bool { player != nil && !desktopHidden && policy.shouldPlay }

    private func updateDesktopVisibility() {
        guard automaticallyPauseWhenOccluded, !windows.isEmpty else { return }
        setDesktopVisible(DesktopCoverage.visible(screens: screens, excluding: Set(windows.map(\.windowNumber))))
    }

    func setAutomaticPause(_ enabled: Bool) {
        automaticallyPauseWhenOccluded = enabled
        if enabled { startVisibilityTimer(); updateDesktopVisibility() }
        else { visibilityTimer?.invalidate(); visibilityTimer = nil; setDesktopVisible(true) }
    }

    private func startVisibilityTimer() {
        guard automaticallyPauseWhenOccluded, visibilityTimer == nil, !windows.isEmpty else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDesktopVisibility() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    // Shared playback continues if at least one of its screens is visible.
    func setDesktopVisible(_ visible: Bool) {
        guard desktopHidden == visible else { return }
        desktopHidden = !visible
        idleRelease?.cancel()
        idleRelease = nil
        if !visible {
            player?.pause()
            if let player { resumeTime = player.currentTime() }
            capturePoster()
            let release = DispatchWorkItem { [weak self] in
                guard let self, self.desktopHidden else { return }
                self.releasePlayback(keepingWindows: true)
            }
            idleRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + idleReleaseDelay, execute: release)
        } else { synchronize() }
        onVisibilityChange?()
    }

    public func loadVideo(_ url: URL) async throws {
        try await Self.validateVideo(url)
        useValidatedVideo(url)
    }

    public static func validateVideo(_ url: URL) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw WallpaperError.missingFile }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        guard playable, !tracks.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
            throw WallpaperError.invalidVideo
        }
        try Task.checkCancellation()
    }

    func useValidatedVideo(_ url: URL) {
        // Validate first: selecting a corrupt file must not destroy the working wallpaper.
        releasePlayback()
        videoURL = url
        resumeTime = .zero
        capturePoster()
        policy.userStopped = false
    }

    public static func validatePhoto(_ url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw WallpaperError.missingFile }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
            throw WallpaperError.invalidPhoto
        }
    }

    public func setPhoto(_ url: URL) throws {
        try Self.validatePhoto(url)
        let workspace = NSWorkspace.shared
        let snapshots = screens.map { screen in
            (screen, workspace.desktopImageURL(for: screen), workspace.desktopImageOptions(for: screen))
        }
        var changed: [(NSScreen, URL?, [NSWorkspace.DesktopImageOptionKey: Any]?)] = []
        do {
            for snapshot in snapshots {
                try workspace.setDesktopImageURL(url, for: snapshot.0, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true
                ])
                changed.append(snapshot)
            }
        } catch {
            for (screen, original, options) in changed {
                if let original { try? workspace.setDesktopImageURL(original, for: screen, options: options ?? [:]) }
            }
            throw error
        }
        clear()
    }

    public func clear() {
        releasePlayback()
        videoURL = nil
    }

    public func refreshDisplays() {
        closeWindows()
        if videoURL != nil, policy.shouldPlay { createWindows(player: player) }
    }

    func setScreens(_ screens: [NSScreen]) {
        let old = self.screens
        targetScreens = screens
        guard old.count != screens.count || zip(old, screens).contains(where: { $0 !== $1 })
            || windows.map(\.frame) != screens.map(\.frame) else { return }
        refreshDisplays()
    }

    private func synchronize() {
        guard policy.shouldPlay, let videoURL else {
            releasePlayback()
            return
        }
        guard !desktopHidden else { return }
        if let player { player.play(); return }
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            policy.userStopped = true
            onFailure?(WallpaperError.missingFile)
            return
        }
        let item = AVPlayerItem(url: videoURL)
        item.preferredForwardBufferDuration = 1
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        player = queue
        if loopMode == .seamless {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        } else {
            queue.actionAtItemEnd = .pause
            queue.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, weak queue] _ in
                Task { @MainActor [weak self, weak queue] in
                    guard let self, let queue, self.player === queue else { return }
                    queue.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak queue] finished in
                        Task { @MainActor [weak self, weak queue] in
                            guard finished, let self, let queue, self.player === queue else { return }
                            self.completedLoops += 1
                            if self.policy.shouldPlay && !self.desktopHidden { queue.play() }
                        }
                    }
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let failed = notification.object as? AVPlayerItem,
                      self.player?.items().contains(where: { $0 === failed }) == true else { return }
                self.policy.userStopped = true
                self.onFailure?(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? WallpaperError.invalidVideo)
            }
        }
        let seek = resumeTime.isNumeric && resumeTime.seconds > 0
        if windows.isEmpty { createWindows(player: queue, waitingForSeek: seek) }
        else { for window in windows { (window.contentView as? VideoView)?.attach(queue, waitingForSeek: seek) } }
        if seek {
            queue.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak queue] finished in
                Task { @MainActor [weak self, weak queue] in
                    guard let self, let queue, self.player === queue else { return }
                    for window in self.windows { (window.contentView as? VideoView)?.completeSeek() }
                    if finished, self.policy.shouldPlay, !self.desktopHidden { queue.play() }
                }
            }
        } else { queue.play() }
    }

    private func createWindows(player: AVQueuePlayer?, waitingForSeek: Bool = false) {
        for screen in screens {
            let window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.animationBehavior = .none
            let view = VideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.setPoster(poster)
            view.attach(player, waitingForSeek: waitingForSeek)
            window.contentView = view
            window.orderBack(nil)
            windows.append(window)
        }
        startVisibilityTimer()
    }

    private func capturePoster() {
        guard let videoURL else { return }
        posterGenerator?.cancelAllCGImageGeneration()
        let token = UUID()
        posterRequest = token
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        posterGenerator = generator
        let time = resumeTime.isNumeric ? resumeTime : .zero
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, image, _, result, _ in
            Task { @MainActor [weak self] in
                guard let self, self.posterRequest == token, self.videoURL == videoURL else { return }
                self.posterGenerator = nil
                guard result == .succeeded, let image else { return }
                self.poster = image
                for window in self.windows { (window.contentView as? VideoView)?.setPoster(image) }
            }
        }
    }

    private func closeWindows() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        for window in windows {
            (window.contentView as? VideoView)?.attach(nil)
            window.close()
            window.contentView = nil
        }
        windows.removeAll()
    }

    private func releasePlayback(keepingWindows: Bool = false) {
        idleRelease?.cancel()
        idleRelease = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player?.pause()
        if keepingWindows {
            for window in windows { (window.contentView as? VideoView)?.attach(nil) }
        } else {
            closeWindows()
            desktopHidden = false
            posterGenerator?.cancelAllCGImageGeneration()
            posterGenerator = nil
            posterRequest = UUID()
            poster = nil
            resumeTime = .zero
        }
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
    }
}

private final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class VideoView: NSView {
    let playerLayer = AVPlayerLayer()
    let posterLayer = CALayer()
    private var readiness: NSKeyValueObservation?
    private var waitingForSeek = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        posterLayer.contentsGravity = .resizeAspectFill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
        layout()
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePresentation() }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPoster(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.contents = image
        CATransaction.commit()
    }

    func attach(_ player: AVQueuePlayer?, waitingForSeek: Bool = false) {
        self.waitingForSeek = waitingForSeek
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = true
        playerLayer.player = player
        CATransaction.commit()
        // Keep the static frame (or transparent system wallpaper) until ready.
        updatePresentation()
    }

    func completeSeek() {
        waitingForSeek = false
        updatePresentation()
    }

    private func updatePresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = playerLayer.player == nil || !playerLayer.isReadyForDisplay || waitingForSeek
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
}
