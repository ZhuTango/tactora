import AppKit

enum DesktopCoverage {
    /// Rectangle subtraction handles tiled windows without counting overlaps twice.
    /// Stop early on complex layouts; uncertainty keeps playback visible.
    static func fullyCovered(_ target: CGRect, by windows: [CGRect]) -> Bool {
        guard !target.isEmpty else { return false }
        var remaining = [target]
        for window in windows {
            var next: [CGRect] = []
            for area in remaining {
                let overlap = area.intersection(window)
                if overlap.isNull || overlap.isEmpty { next.append(area); continue }
                let pieces = [
                    CGRect(x: area.minX, y: area.minY, width: area.width, height: overlap.minY - area.minY),
                    CGRect(x: area.minX, y: overlap.maxY, width: area.width, height: area.maxY - overlap.maxY),
                    CGRect(x: area.minX, y: overlap.minY, width: overlap.minX - area.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: area.maxX - overlap.maxX, height: overlap.height)
                ]
                next.append(contentsOf: pieces.filter { !$0.isEmpty })
            }
            remaining = next
            if remaining.isEmpty { return true }
            if remaining.count > 256 { return false }
        }
        return false
    }

    @MainActor static func visible(screens: [NSScreen], excluding windowIDs: Set<Int>) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let main = NSScreen.screens.first else { return true }
        let bounds = info.compactMap { entry -> CGRect? in
            guard let id = entry[kCGWindowNumber as String] as? Int, !windowIDs.contains(id),
                  let level = entry[kCGWindowLayer as String] as? Int, level >= 0, level <= 3,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha >= 0.999,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return rect
        }
        return screens.contains { screen in
            let frame = screen.visibleFrame
            let target = CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            return !fullyCovered(target, by: bounds)
        }
    }
}
