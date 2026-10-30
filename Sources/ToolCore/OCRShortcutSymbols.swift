import Foundation
import CoreGraphics
import CoreText
import Vision

/// Recognizes modifier glyphs from pixels, never from substitutions such as "9个".
/// Only confident, spatially aligned glyphs adjacent to a shortcut key are repaired.
enum OCRShortcutSymbols {
    private struct Shape {
        let rect: CGRect
        let pixels: [Bool]
    }
    private struct Template {
        let symbol: String
        let aspect: CGFloat
        let pixels: [Bool]
    }
    private static let side = 32
    private static let templates: [Template] = {
        var result: [Template] = []
        for symbol in ["⌘", "⇧"] {
            for name in [".AppleSystemUIFont", "HelveticaNeue", "Arial"] {
                for bold in [false, true] {
                    for size: CGFloat in [24, 28, 32, 40] {
                        let base = CTFontCreateWithName(name as CFString, size, nil)
                        let font = bold ? (CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base) : base
                        guard let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { continue }
                        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
                        context.textPosition = CGPoint(x: 10, y: 15)
                        let string = NSAttributedString(string: symbol, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
                        CTLineDraw(CTLineCreateWithAttributedString(string), context)
                        if let image = context.makeImage(), let shape = shapes(image).max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
                            result.append(Template(symbol: symbol, aspect: shape.rect.width / shape.rect.height, pixels: shape.pixels))
                        }
                    }
                }
            }
        }
        return result
    }()

    static func repair(_ text: VNRecognizedText, bounds: CGRect, image: CGImage) -> String {
        let source = text.string
        // Restrict the additional image work to lines that can contain a keyboard shortcut.
        guard source.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return source }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = CGRect(x: bounds.minX * width, y: (1 - bounds.maxY) * height, width: bounds.width * width, height: bounds.height * height)
            .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let crop = image.cropping(to: rect) else { return source }
        let indices = Array(source.indices)
        let boxes: [CGRect?] = indices.map { index in
            (try? text.boundingBox(for: index..<source.index(after: index)))?.boundingBox
        }
        var replacements: [(Range<Int>, String)] = []
        for shape in shapes(crop) {
            let aspect = shape.rect.width / shape.rect.height
            guard shape.rect.height >= 8, shape.rect.width >= 8, (0.75...1.35).contains(aspect) else { continue }
            var best: (String, Double) = ("", 0)
            for template in templates where abs(template.aspect - aspect) < 0.20 {
                let intersection = zip(shape.pixels, template.pixels).reduce(0) { $0 + ($1.0 && $1.1 ? 1 : 0) }
                let union = zip(shape.pixels, template.pixels).reduce(0) { $0 + ($1.0 || $1.1 ? 1 : 0) }
                let score = Double(intersection) / Double(max(1, union))
                if score > best.1 { best = (template.symbol, score) }
            }
            guard best.1 >= 0.78 else { continue }
            let left = (rect.minX + shape.rect.minX) / width, right = (rect.minX + shape.rect.maxX) / width
            let matches = boxes.indices.filter { i in
                guard let box = boxes[i], box.width > 0 else { return false }
                let overlap = max(0, min(box.maxX, right) - max(box.minX, left))
                return overlap / min(box.width, right - left) >= 0.55
            }
            guard let first = matches.first, let last = matches.last, last - first <= 2 else { continue }
            replacements.append((first..<(last + 1), best.0))
        }
        // A standalone Chinese character or number must never become a modifier.
        // Require a contiguous modifier sequence followed immediately by an ASCII key.
        replacements.sort { $0.0.lowerBound < $1.0.lowerBound }
        var accepted: [(Range<Int>, String)] = []
        for replacement in replacements {
            var end = replacement.0.upperBound
            for next in replacements where next.0.lowerBound == end { end = next.0.upperBound }
            guard end < indices.count else { continue }
            let key = source[indices[end]]
            guard key.isASCII && (key.isLetter || key.isNumber),
                  !accepted.contains(where: { $0.0.overlaps(replacement.0) }) else { continue }
            accepted.append(replacement)
        }
        var output = source
        for (range, symbol) in accepted.reversed() {
            let start = output.index(output.startIndex, offsetBy: range.lowerBound)
            let end = output.index(output.startIndex, offsetBy: range.upperBound)
            output.replaceSubrange(start..<end, with: symbol)
        }
        return output
    }

    private static func shapes(_ image: CGImage) -> [Shape] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        let lightBackground = (0..<(w * h)).reduce(0) { $0 + (bytes[$1] > 127 ? 1 : 0) } > w * h / 2
        var foreground = (0..<(w * h)).map { lightBackground ? bytes[$0] < 127 : bytes[$0] > 127 }
        var result: [Shape] = []
        for seed in 0..<(w * h) where foreground[seed] {
            foreground[seed] = false
            var queue = [seed], cursor = 0
            var minX = seed % w, maxX = minX, minY = seed / w, maxY = minY
            while cursor < queue.count {
                let p = queue[cursor]; cursor += 1
                let x = p % w, y = p / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let n = ny * w + nx
                    if foreground[n] { foreground[n] = false; queue.append(n) }
                }
            }
            let sw = maxX - minX + 1, sh = maxY - minY + 1
            guard sw >= 8, sh >= 8, sw <= sh * 2, sh <= sw * 2 else { continue }
            let set = Set(queue)
            var normalized = [Bool](repeating: false, count: side * side)
            for y in 0..<side { for x in 0..<side {
                let px = minX + min(sw - 1, Int((Double(x) + 0.5) * Double(sw) / Double(side)))
                let py = minY + min(sh - 1, Int((Double(y) + 0.5) * Double(sh) / Double(side)))
                normalized[y * side + x] = set.contains(py * w + px)
            } }
            result.append(Shape(rect: CGRect(x: minX, y: minY, width: sw, height: sh), pixels: normalized))
        }
        return result
    }
}
