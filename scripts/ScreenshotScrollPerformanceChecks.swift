import AppKit

@main struct ScreenshotScrollPerformanceChecks {
    static func main() throws {
        let width = 1200, height = 3000, viewport = 1000
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var random: UInt64 = 42
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            random = random &* 6364136223846793005 &+ 1
            bytes[i] = UInt8(truncatingIfNeeded: random >> 24)
            bytes[i + 1] = UInt8(truncatingIfNeeded: random >> 32)
            bytes[i + 2] = UInt8(truncatingIfNeeded: random >> 40)
            bytes[i + 3] = 255
        }
        let full = context.makeImage()!
        func frame(_ offset: Int) -> CGImage { full.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport))! }
        let first = frame(0), next = frame(120)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            let shift = try ScreenshotScrollStitcher.verticalShift(from: first, to: next)
            precondition(shift == 120)
        }
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 100
        print(String(format: "Match 1200×1000: %.2f ms/frame (optimized build)", milliseconds))
        precondition(milliseconds < 25, "Matching must leave room in a 30fps frame budget")

        // Replay the actual producer/consumer boundary: capture 30fps, a consumer
        // briefly stalled for 100ms, then finish while several frames remain queued.
        let stream = ScreenshotStream(framesPerSecond: 30)
        var stitcher = ScreenshotScrollStitcher()
        for index in 0...15 {
            stream.storeScrollFrame(frame(index * 120))
            if index % 3 == 0 {
                while let image = stream.nextScrollFrame() { try stitcher.append(image) }
            }
        }
        stream.storeScrollFrame(frame(1920))
        stream.storeScrollFrame(frame(2000))
        let finalFrames = stream.finishScrollFrames()
        precondition(finalFrames.count == 2, "Finish must retain intermediate overlaps")
        stream.storeScrollFrame(frame(1500))
        precondition(stream.nextScrollFrame() == nil, "Finish freezes the accepted queue")
        for image in finalFrames { try stitcher.append(image) }
        precondition(stitcher.result!.height == height)
        func pixels(_ image: CGImage) -> Data {
            let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: c.data!, count: image.width * image.height * 4)
        }
        precondition(pixels(stitcher.result!) == pixels(full), "Fast scrolling must not skip or duplicate rows")
        stream.resetScrollFrames()
        precondition(stream.nextScrollFrame()!.height == viewport)
        precondition(stream.nextScrollFrame() == nil, "Reset must drop earlier backlog")
        var buffer = ScreenshotFrameBuffer()
        for _ in 0..<40 { buffer.append(first) }
        precondition(buffer.count <= 12 && buffer.bytes <= 64 * 1024 * 1024)
        _ = buffer.drain()
        precondition(buffer.count == 0 && buffer.bytes == 0)
        print("PASS fast-scroll replay, intermediate frame order, finish drain, reset and bounded memory")
    }
}
