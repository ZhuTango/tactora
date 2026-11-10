import AppKit
import ScreenCaptureKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// SCStream callbacks and the writer share one queue. UI reads snapshots under a lock.
final class ScreenshotStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.tango.screenshot.stream", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CGImage?
    private var failure: Error?
    private let context = CIContext()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var accepting = true
    private var lastTime: CMTime?
    private var firstTime: CMTime?
    private var firstFrameDate: Date?
    private let framesPerSecond: Int
    init(framesPerSecond: Int) { self.framesPerSecond = framesPerSecond }

    var snapshot: CGImage? { lock.lock(); defer { lock.unlock() }; return latest }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    private func recordError(_ error: Error) { lock.lock(); failure = error; lock.unlock() }

    func start(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat, movieURL: URL?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "TactoraCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "录制屏幕已断开"])
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        let maxWidth: CGFloat = movieURL == nil ? 4096 : 1920
        let ratio = min(scale, maxWidth / max(rect.width, rect.height))
        configuration.width = max(2, Int(rect.width * ratio) / 2 * 2)
        configuration.height = max(2, Int(rect.height * ratio) / 2 * 2)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(framesPerSecond))
        configuration.queueDepth = 3
        configuration.showsCursor = movieURL != nil
        configuration.capturesAudio = false
        if let movieURL { try prepareMovie(at: movieURL, width: configuration.width, height: configuration.height) }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do { try await stream.startCapture() }
        catch { writer?.cancelWriting(); throw error }
    }
    func prepareMovie(at url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Self.encodingError("无法创建视频编码器") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Self.encodingError("无法开始视频编码") }
        self.writer = writer
        self.input = input
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { recordError(error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if writer == nil {
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = context.createCGImage(image, from: image.extent) {
                lock.lock(); latest = cg; lock.unlock()
            }
        }
        appendMovieFrame(sampleBuffer)
    }
    func appendMovieFrame(_ sampleBuffer: CMSampleBuffer) {
        guard accepting, let writer, let input, input.isReadyForMoreMediaData else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            writer.startSession(atSourceTime: time)
            firstTime = time
            firstFrameDate = Date()
            started = true
        }
        if !input.append(sampleBuffer) { recordError(writer.error ?? Self.encodingError("视频写入失败")) }
        lastTime = time
    }
    func stop(cancel: Bool) async throws {
        // Always drain the writer, including when the display disappears during recording.
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.accepting = false
                guard let writer = self.writer, let input = self.input else {
                    if let stopError, !cancel { continuation.resume(throwing: stopError) }
                    else { continuation.resume() }
                    return
                }
                if cancel || !self.started {
                    writer.cancelWriting()
                    if cancel { continuation.resume() }
                    else { continuation.resume(throwing: Self.encodingError("没有录制到画面，请重试")) }
                    return
                }
                if let lastTime = self.lastTime {
                    let sampleEnd = CMTimeAdd(lastTime, CMTime(value: 1, timescale: Int32(self.framesPerSecond)))
                    let wallEnd = CMTimeAdd(self.firstTime ?? lastTime, CMTime(seconds: Date().timeIntervalSince(self.firstFrameDate ?? Date()), preferredTimescale: 600))
                    writer.endSession(atSourceTime: CMTimeMaximum(sampleEnd, wallEnd))
                }
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? Self.encodingError("视频未能完成写入")) }
                }
            }
        }
    }
    static func encodingError(_ message: String) -> NSError {
        NSError(domain: "TactoraCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func makeGIF(movie: URL, destination: URL, fps: Int) throws {
        let asset = AVURLAsset(url: movie)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { throw encodingError("视频时长无效") }
        let count = max(1, Int(min(60, duration) * Double(fps)))
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw encodingError("无法创建 GIF 文件") }
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: Int32(fps))
        for index in 0..<count {
            try autoreleasepool {
                let image = try generator.copyCGImage(at: CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 600), actualTime: nil)
                CGImageDestinationAddImage(output, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(output) else { throw encodingError("GIF 编码失败") }
    }
}
