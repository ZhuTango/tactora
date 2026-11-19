import AppKit
import CoreImage

enum QuickInputActions {
    static func webURL(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    static func date(_ text: String, now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let offsets = ["今天": 0, "明天": 1, "昨天": -1, "today": 0, "tomorrow": 1, "yesterday": -1]
        if let offset = offsets[text.lowercased()] { return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) }
        guard text.count <= 16 else { return nil }
        let normalized = text.replacingOccurrences(of: "年", with: "-").replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: "").replacingOccurrences(of: "/", with: "-")
        var fields = normalized.split(separator: "-", omittingEmptySubsequences: false)
        if fields.count == 2, text.contains("月") { fields.insert(Substring(String(calendar.component(.year, from: now))), at: 0) }
        guard fields.count == 3, fields[0].count == 4, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let y = Int(fields[0]), let m = Int(fields[1]), let d = Int(fields[2]), (1...9999).contains(y),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              calendar.dateComponents([.year,.month,.day], from: date).day == d,
              calendar.component(.month, from: date) == m else { return nil }
        return date
    }

    static func unitResult(_ input: String) -> String? {
        guard input.count <= 96 else { return nil }
        let units: [String: (String, Double)] = [
            "mm": ("length", 0.001), "cm": ("length", 0.01), "m": ("length", 1), "km": ("length", 1000),
            "in": ("length", 0.0254), "ft": ("length", 0.3048), "mi": ("length", 1609.344),
            "g": ("mass", 1), "kg": ("mass", 1000), "lb": ("mass", 453.59237),
            "s": ("time", 1), "min": ("time", 60), "h": ("time", 3600),
            "b": ("data", 1), "kb": ("data", 1000), "mb": ("data", 1e6), "gb": ("data", 1e9),
            "kib": ("data", 1024), "mib": ("data", 1048576), "gib": ("data", 1073741824)]
        let aliases = [("千米","km"), ("公里","km"), ("毫米","mm"), ("厘米","cm"), ("英尺","ft"), ("英寸","in"), ("英里","mi"), ("米","m"), ("千克","kg"), ("公斤","kg"), ("克","g"), ("磅","lb"), ("分钟","min"), ("小时","h"), ("秒","s"), ("摄氏度","c"), ("华氏度","f"), ("°c","c"), ("°f","f")]
        let pattern = #"^([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*([a-z]+)\s*(?:to|转|换算为|→|=)\s*([a-z]+)$"#
        let text = aliases.reduce(input.lowercased()) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let parts = (1...3).map { (text as NSString).substring(with: match.range(at: $0)) }
        guard let number = Double(parts[0]), number.isFinite else { return nil }
        if ["c", "f"].contains(parts[1]), ["c", "f"].contains(parts[2]) {
            let value = parts[1] == parts[2] ? number : (parts[2] == "f" ? number * 1.8 + 32 : (number - 32) / 1.8)
            guard value.isFinite else { return nil }
            return String(format: "%.12g °%@", locale: Locale(identifier: "en_US_POSIX"), value, parts[2].uppercased())
        }
        guard let from = units[parts[1]], let to = units[parts[2]], from.0 == to.0 else { return nil }
        let result = number * from.1 / to.1
        guard result.isFinite else { return nil }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), result) + " " + (to.0 == "data" ? parts[2].uppercased().replacingOccurrences(of: "IB", with: "iB") : parts[2])
    }

    static func qrImage(_ url: URL) -> NSImage? {
        guard url.absoluteString.utf8.count <= 2331, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let bounds = code.extent.insetBy(dx: -4, dy: -4)
        let padded = code.composited(over: CIImage(color: .white).cropped(to: bounds))
        let image = padded.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
