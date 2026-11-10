import AppKit

/// Coordinates are source-image pixels with a bottom-left origin.
enum ScreenshotSelection {
    static func handles(_ rect: NSRect) -> [NSPoint] {
        [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY),
         NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.midY),
         NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY),
         NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.midY)]
    }
    static func hitHandle(_ point: NSPoint, rect: NSRect, tolerance: CGFloat) -> Int? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        if let index = handles(rect).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= tolerance }) { return index }
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        if abs(point.x - rect.minX) <= tolerance { return 7 }
        if abs(point.x - rect.maxX) <= tolerance { return 3 }
        if abs(point.y - rect.minY) <= tolerance { return 1 }
        if abs(point.y - rect.maxY) <= tolerance { return 5 }
        return nil
    }
    static func drag(handle: Int, start: NSPoint, point: NSPoint, original: NSRect, bounds: NSRect) -> NSRect {
        if handle == -1 {
            let first = NSPoint(x: min(bounds.maxX, max(bounds.minX, start.x)), y: min(bounds.maxY, max(bounds.minY, start.y)))
            let last = NSPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
            // Preserve finite zero-size geometry while a drag starts or follows one axis.
            return NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
        }
        if handle == -2 {
            let x = min(bounds.maxX - original.width, max(bounds.minX, original.minX + point.x - start.x))
            let y = min(bounds.maxY - original.height, max(bounds.minY, original.minY + point.y - start.y))
            return NSRect(origin: NSPoint(x: x, y: y), size: original.size)
        }
        var left = original.minX, right = original.maxX, bottom = original.minY, top = original.maxY
        if [0, 6, 7].contains(handle) { left = min(right - 2, max(bounds.minX, point.x)) }
        if [2, 3, 4].contains(handle) { right = max(left + 2, min(bounds.maxX, point.x)) }
        if [0, 1, 2].contains(handle) { bottom = min(top - 2, max(bounds.minY, point.y)) }
        if [4, 5, 6].contains(handle) { top = max(bottom + 2, min(bounds.maxY, point.y)) }
        return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
