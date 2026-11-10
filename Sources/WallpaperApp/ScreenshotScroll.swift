import AppKit

/// Downward scrolling only. Ambiguous matches leave the existing result intact.
struct ScreenshotScrollStitcher {
    private(set) var result: CGImage?
    private var previous: CGImage?
    private(set) var count = 0

    enum StitchError: LocalizedError {
        case mismatch, unchanged, limit
        var errorDescription: String? {
            switch self {
            case .mismatch: return "无法可靠拼接。请向下滚动约半屏，保持窗口与选区位置不变，避开固定页眉、视频和动画。"
            case .unchanged: return "画面没有变化，请向下滚动后再添加。"
            case .limit: return "长截图已达上限（30 帧、30000 像素高或 6000 万像素），请完成当前截图。"
            }
        }
    }
    mutating func append(_ image: CGImage) throws {
        guard let previous, let result else { self.previous = image; result = image; count = 1; return }
        guard count < 30, previous.width == image.width, previous.height == image.height else { throw StitchError.limit }
        let shift = try Self.verticalShift(from: previous, to: image)
        let height = result.height + shift
        guard height <= 30_000, result.width * height <= 60_000_000,
              let context = CGContext(data: nil, width: result.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let tail = image.cropping(to: CGRect(x: 0, y: image.height - shift, width: image.width, height: shift)) else { throw StitchError.limit }
        context.draw(result, in: CGRect(x: 0, y: shift, width: result.width, height: result.height))
        context.draw(tail, in: CGRect(x: 0, y: 0, width: image.width, height: shift))
        guard let merged = context.makeImage() else { throw StitchError.limit }
        self.result = merged
        self.previous = image
        count += 1
    }
    static func verticalShift(from old: CGImage, to new: CGImage) throws -> Int {
        guard old.width == new.width, old.height == new.height, old.height >= 64 else { throw StitchError.mismatch }
        let columns = 48
        func samples(_ image: CGImage) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: columns, height: image.height, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: image.height))
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: columns * image.height * 4))
        }
        guard let a = samples(old), let b = samples(new) else { throw StitchError.mismatch }
        func error(_ shift: Int) -> Double {
            var difference = 0
            var count = 0
            let overlap = old.height - shift
            let rowStep = max(1, overlap / 100)
            for y in stride(from: 0, to: overlap, by: rowStep) {
                for x in 2..<(columns - 2) {
                    let p = ((y + shift) * columns + x) * 4
                    let q = (y * columns + x) * 4
                    for component in 0..<3 { difference += abs(Int(a[p + component]) - Int(b[q + component])) }
                    count += 3
                }
            }
            return Double(difference) / Double(max(1, count))
        }
        if error(0) < 0.5 { throw StitchError.unchanged }
        let matches = (8...Int(Double(old.height) * 0.8)).map { ($0, error($0)) }.sorted { $0.1 < $1.1 }
        guard let best = matches.first, best.1 < 4,
              let alternative = matches.first(where: { abs($0.0 - best.0) > 8 }), alternative.1 > best.1 + 0.6 else { throw StitchError.mismatch }
        return best.0
    }
}
