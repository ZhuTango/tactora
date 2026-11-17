import AppKit

/// Bidirectional vertical capture. Track the viewport inside the accumulated image
/// so revisiting captured content never duplicates rows. Ambiguous matches are rejected.
struct ScreenshotScrollStitcher {
    private(set) var result: CGImage?
    private var previous: CGImage?
    private var previousOrigin = 0
    private(set) var count = 0

    enum StitchError: LocalizedError {
        case mismatch, unchanged, limit
        var errorDescription: String? {
            switch self {
            case .mismatch: return "无法可靠拼接。请向上或向下缓慢滚动，保持窗口与选区位置不变，避开固定页眉、视频和动画。"
            case .unchanged: return "画面没有变化，请滚动后继续。"
            case .limit: return "长截图已达上限（30000 像素高或 6000 万像素），请完成当前截图。"
            }
        }
    }
    mutating func append(_ image: CGImage) throws {
        guard let previous, let result else { self.previous = image; result = image; count = 1; return }
        guard previous.width == image.width, previous.height == image.height else { throw StitchError.limit }
        let shift = try Self.verticalShift(from: previous, to: image)
        let origin = previousOrigin + shift
        let prepend = max(0, -origin)
        let append = max(0, origin + image.height - result.height)
        let height = result.height + prepend + append
        guard height <= 30_000, result.width * height <= 60_000_000 else { throw StitchError.limit }
        if prepend > 0 || append > 0 {
            guard let context = CGContext(data: nil, width: result.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.limit }
            context.draw(result, in: CGRect(x: 0, y: append, width: result.width, height: result.height))
            if prepend > 0 {
                guard let head = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: prepend)) else { throw StitchError.limit }
                context.draw(head, in: CGRect(x: 0, y: height - prepend, width: image.width, height: prepend))
            }
            if append > 0 {
                guard let tail = image.cropping(to: CGRect(x: 0, y: image.height - append, width: image.width, height: append)) else { throw StitchError.limit }
                context.draw(tail, in: CGRect(x: 0, y: 0, width: image.width, height: append))
            }
            guard let merged = context.makeImage() else { throw StitchError.limit }
            self.result = merged
        }
        self.previous = image
        previousOrigin = origin + prepend
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
            let overlap = old.height - abs(shift)
            let rowStep = max(1, overlap / 100)
            // A lower bound on the final mean error: reject only once even
            // perfectly matching remaining samples cannot pass the threshold.
            let sampleCount = ((overlap + rowStep - 1) / rowStep) * (columns - 4) * 3
            let maximumDifference = Int(4.6 * Double(sampleCount))
            for y in stride(from: 0, to: overlap, by: rowStep) {
                for x in 2..<(columns - 2) {
                    let p = ((y + max(0, shift)) * columns + x) * 4
                    let q = ((y + max(0, -shift)) * columns + x) * 4
                    for component in 0..<3 { difference += abs(Int(a[p + component]) - Int(b[q + component])) }
                    count += 3
                }
                if difference > maximumDifference { return 5 }
            }
            return Double(difference) / Double(max(1, count))
        }
        if error(0) < 0.5 { throw StitchError.unchanged }
        let maximum = Int(Double(old.height) * 0.85)
        let matches = (-maximum...maximum).filter { $0 != 0 }.map { ($0, error($0)) }.sorted { $0.1 < $1.1 }
        guard let best = matches.first, best.1 < 4,
              let alternative = matches.first(where: { abs($0.0 - best.0) > 8 }), alternative.1 > best.1 + 0.6 else { throw StitchError.mismatch }
        return best.0
    }
}
