import AppKit
import AVFoundation
import AVKit
import ImageIO

@main
struct ScreenshotExtrasChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let button = ScreenshotToolButton(frame: NSRect(x: 0, y: 0, width: 32, height: 30))
        button.wantsLayer = true
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        button.mouseEntered(with: event)
        precondition(button.hovered && (button.layer?.backgroundColor?.alpha ?? 0) > 0)
        button.state = .on
        button.mouseExited(with: event)
        precondition(!button.hovered && (button.layer?.backgroundColor?.alpha ?? 0) > 0)
        button.isEnabled = false
        precondition(button.layer?.backgroundColor?.alpha == 0)
        print("PASS hover, selected and disabled backgrounds")

        // Random row/column data makes any wrong offset distinguishable.
        let width = 160, height = 800
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var random: UInt64 = 123
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            random = random &* 6364136223846793005 &+ 1
            bytes[index] = UInt8(truncatingIfNeeded: random >> 24)
            bytes[index + 1] = UInt8(truncatingIfNeeded: random >> 32)
            bytes[index + 2] = UInt8(truncatingIfNeeded: random >> 40)
            bytes[index + 3] = 255
        }
        let full = context.makeImage()!
        let first = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: 400))!
        let second = full.cropping(to: CGRect(x: 0, y: 150, width: width, height: 400))!
        let shift = try ScreenshotScrollStitcher.verticalShift(from: first, to: second)
        precondition(shift == 150)
        var stitcher = ScreenshotScrollStitcher()
        try stitcher.append(first)
        try stitcher.append(second)
        precondition(stitcher.result?.height == 550 && stitcher.count == 2)
        let expected = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: 550))!
        func pixels(_ image: CGImage) -> Data {
            let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: c.data!, count: image.width * image.height * 4)
        }
        precondition(pixels(stitcher.result!) == pixels(expected), "Stitched pixels must exactly match the full page")
        do { try stitcher.append(second); preconditionFailure("Unchanged frame accepted") }
        catch ScreenshotScrollStitcher.StitchError.unchanged {}
        let unrelated = first
        do { try stitcher.append(unrelated); preconditionFailure("Unmatched frame accepted") }
        catch ScreenshotScrollStitcher.StitchError.mismatch {}
        precondition(stitcher.count == 2)
        print("PASS scroll overlap, pixel-exact stitching, unchanged/mismatched frame rejection")

        let image = NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
        var style = ScreenshotAppearance()
        let original = style.render(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(pixels(original) == pixels(first))
        style.watermark = "Tactora 测试"
        let marked = style.render(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(pixels(marked) != pixels(first))
        style.tiled = true
        style.background = 1
        let decorated = style.render(image)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(decorated.width == 256 && decorated.height == 496)
        print("PASS plain export fidelity, watermark pixels, background padding")

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let sheet = ScreenshotAppearanceSheet(image: image, value: ScreenshotAppearance())
            let panel = sheet.window!
            panel.appearance = NSAppearance(named: appearance)
            let root = panel.contentView!
            root.layoutSubtreeIfNeeded()
            precondition(root.frame.width == 560 && root.frame.height <= 416)
            let stack = root.subviews.first as! NSStackView
            precondition(stack.arrangedSubviews.count == 6)
            for row in stack.arrangedSubviews {
                precondition(root.bounds.insetBy(dx: -1, dy: -1).contains(row.convert(row.bounds, to: root)), "Appearance row must fit")
            }
            panel.close()
        }
        print("PASS compact appearance layout in light and dark modes")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("test.mp4")
        let engine = ScreenshotStream(framesPerSecond: 15)
        try engine.prepareMovie(at: movie, width: 160, height: 120)
        var lastSample: CMSampleBuffer?
        for index in 0..<30 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
            let pixel = buffer!
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(index * 6), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(value: Int64(index), timescale: 15), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
            lastSample = sample
            engine.appendMovieFrame(sample!)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await engine.stop(cancel: false)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        precondition(CMTimeGetSeconds(duration) >= 1.9)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        let gif = directory.appendingPathComponent("test.gif")
        try await Task.detached { try ScreenshotStream.makeGIF(movie: movie, destination: gif, fps: 8) }.value
        let gifSource = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        precondition(CGImageSourceGetCount(gifSource) >= 15)
        precondition(CGImageSourceCreateImageAtIndex(gifSource, 0, nil) != nil)
        print("PASS native MP4 writer, duration, video track and multi-frame GIF export")
        for isGIF in [true, false] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let view = ScreenshotRecordingResultView(url: isGIF ? gif : movie, isGIF: isGIF)
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.appearance = NSAppearance(named: appearance)
                panel.contentView = view
                panel.setContentSize(NSSize(width: 680, height: 420))
                view.layoutSubtreeIfNeeded()
                func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
                let all = descendants(view)
                let stage = all.first { $0.identifier?.rawValue == "recording.result.preview" }!
                precondition(stage.frame.width > 600 && stage.frame.height > 200, "Preview bounds \(stage.frame), root \(view.frame)")
                let save = all.first { $0.identifier?.rawValue == "recording.result.save" } as! NSButton
                var saves = 0
                view.onSave = { saves += 1 }
                save.performClick(nil)
                precondition(saves == 1)
                view.showSaved(isGIF ? gif : movie)
                view.layoutSubtreeIfNeeded()
                precondition(save.title == "另存为…")
                let buttons = all.compactMap { $0 as? NSButton }.filter { !$0.isHidden && !($0.superview is AVPlayerView) }
                precondition(buttons.contains { $0.title == "在 Finder 中显示" && !$0.isHidden })
                precondition(buttons.contains { $0.title == "复制 GIF" } == isGIF)
                precondition(view.metadata.contains("160 × 120"))
                view.showStatus("保存失败，可重试")
                let status = all.first { $0.identifier?.rawValue == "recording.result.status" } as! NSTextField
                precondition(status.stringValue == "保存失败，可重试")
                view.stopPlayback()
                panel.close()
            }
        }
        if let screen = NSScreen.main {
            for mode in [ScreenshotSession.Mode.video, .gif, .scroll] {
                let session = try ScreenshotSession(mode: mode, screen: screen, region: CGRect(x: 0, y: 0, width: 800, height: 400), fps: 15)
                let root = session.window!.contentView!
                root.layoutSubtreeIfNeeded()
                let expected = mode == .scroll ? NSSize(width: 340, height: 276) : NSSize(width: 302, height: 56)
                precondition(root.frame.size == expected, "Compact session size \(root.frame.size)")
                let stack = root.subviews.first as! NSStackView
                for row in stack.arrangedSubviews {
                    precondition(root.bounds.insetBy(dx: -1, dy: -1).contains(row.convert(row.bounds, to: root)), "Session controls must fit")
                }
                session.showRecordingResult(mode == .gif ? gif : movie)
                session.cancel()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        print("PASS compact recording and scrolling session layouts")
        let largeGIF = directory.appendingPathComponent("large.gif")
        let largeContext = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        largeContext.draw(first, in: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let largeDestination = CGImageDestinationCreateWithURL(largeGIF as CFURL, "com.compuserve.gif" as CFString, 1, nil)!
        CGImageDestinationAddImage(largeDestination, largeContext.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(largeDestination))
        let largeView = ScreenshotRecordingResultView(url: largeGIF, isGIF: true)
        let largePanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        largePanel.isReleasedWhenClosed = false
        largePanel.contentView = largeView
        largePanel.setContentSize(NSSize(width: 740, height: 540))
        largeView.layoutSubtreeIfNeeded()
        precondition(largeView.frame.size == NSSize(width: 740, height: 540), "Large media must fit inside the preview without expanding the window")
        largeView.stopPlayback()
        largePanel.close()
        print("PASS GIF/video result preview, light/dark minimum layout, save action, saved and retry states")
        let stillURL = directory.appendingPathComponent("still.mp4")
        let still = ScreenshotStream(framesPerSecond: 15)
        try still.prepareMovie(at: stillURL, width: 160, height: 120)
        still.appendMovieFrame(lastSample!)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await still.stop(cancel: false)
        let stillDuration = try await AVURLAsset(url: stillURL).load(.duration)
        precondition(CMTimeGetSeconds(stillDuration) >= 0.9, "Static capture must preserve elapsed duration")
        let stillGIF = directory.appendingPathComponent("still.gif")
        try await Task.detached { try ScreenshotStream.makeGIF(movie: stillURL, destination: stillGIF, fps: 8) }.value
        print("PASS static recording duration and GIF hold frames")
        let cancelled = ScreenshotStream(framesPerSecond: 15)
        try cancelled.prepareMovie(at: directory.appendingPathComponent("cancel.mp4"), width: 160, height: 120)
        try await cancelled.stop(cancel: true)
        print("PASS cancel before first frame")
    }
}
