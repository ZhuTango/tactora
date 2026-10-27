import Foundation
import AVFoundation
import CryptoKit

/// Export only on demand. Concurrent screens share the same in-flight conversion.
actor VideoCache {
    static let shared = VideoCache()
    let directory: URL
    private struct Job { let task: Task<URL, Error>; var clients: Set<UUID> }
    private var jobs: [String: Job] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.tango.macbglive/video-v1", isDirectory: true)) {
        self.directory = directory
    }

    func prepare(_ source: URL, quality: VideoQuality) async throws -> URL {
        try Task.checkCancellation()
        guard quality != .original else { return source }
        let canonical = source.standardizedFileURL.resolvingSymlinksInPath()
        let values = try canonical.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = "v1|\(canonical.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(quality.rawValue)"
        let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(key + ".mp4")
        let client = UUID()
        let task: Task<URL, Error>
        if var job = jobs[key] {
            job.clients.insert(client)
            jobs[key] = job
            task = job.task
        } else {
            task = Task { try await Self.export(source: canonical, destination: destination, quality: quality) }
            jobs[key] = Job(task: task, clients: [client])
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                release(key, client: client)
                try Task.checkCancellation()
                return result
            } catch {
                release(key, client: client)
                throw error
            }
        } onCancel: {
            Task { await self.release(key, client: client) }
        }
    }

    private func release(_ key: String, client: UUID) {
        guard var job = jobs[key], job.clients.remove(client) != nil else { return }
        if job.clients.isEmpty {
            jobs.removeValue(forKey: key)
            job.task.cancel()
        } else { jobs[key] = job }
    }

    private static func export(source: URL, destination: URL, quality: VideoQuality) async throws -> URL {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            let cached = AVURLAsset(url: destination)
            if (try? await cached.load(.isPlayable)) == true,
               (try? await cached.load(.duration).seconds) ?? 0 > 0 {
                return destination
            }
            try FileManager.default.removeItem(at: destination)
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw WallpaperError.invalidVideo }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let sourceSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        guard sourceSize.width > 0, sourceSize.height > 0 else { throw WallpaperError.invalidVideo }
        let fps = try await track.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var limit = quality.maximumSize
        if sourceSize.height > sourceSize.width { limit = CGSize(width: limit.height, height: limit.width) }
        let ratio = min(1, limit.width / sourceSize.width, limit.height / sourceSize.height)
        // Already-small, silent clips do not need a redundant copy or re-encode.
        if ratio == 1, fps > 0, fps <= 30, audio.isEmpty { return source }
        let size = CGSize(width: max(2, floor(sourceSize.width * ratio / 2) * 2),
                          height: max(2, floor(sourceSize.height * ratio / 2) * 2))
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw WallpaperError.invalidVideo
        }
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try video.insertTimeRange(range, of: track, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        let normalized = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: size.width / sourceSize.width, y: size.height / sourceSize.height))
        layer.setTransform(normalized, at: .zero)
        instruction.layerInstructions = [layer]
        let settings = AVMutableVideoComposition()
        settings.renderSize = size
        settings.frameDuration = CMTime(seconds: 1 / Double(fps > 0 ? min(fps, 30) : 30), preferredTimescale: 60_000)
        settings.instructions = [instruction]
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw WallpaperError.invalidVideo
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary
        exporter.outputFileType = .mp4
        exporter.videoComposition = settings
        exporter.shouldOptimizeForNetworkUse = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                exporter.exportAsynchronously { continuation.resume() }
            }
            try Task.checkCancellation()
            guard exporter.status == .completed else {
                throw exporter.error ?? WallpaperError.invalidVideo
            }
        } onCancel: { exporter.cancelExport() }
        // The completed file is the only name ever visible as a cache hit.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
