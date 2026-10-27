import AppKit

enum VideoQuality: String, Codable, CaseIterable {
    case economy, balanced, original
    var title: String {
        switch self {
        case .economy: return "低耗 · 1080p / 30 fps"
        case .balanced: return "均衡 · 1440p / 30 fps"
        case .original: return "原画 · 原始分辨率和帧率"
        }
    }
    var maximumSize: CGSize {
        self == .balanced ? CGSize(width: 2560, height: 1440) : CGSize(width: 1920, height: 1080)
    }
}

public enum VideoLoopMode: String, Codable, CaseIterable {
    case efficient, seamless
    var title: String { self == .efficient ? "低内存循环（接缝可能短暂停顿）" : "无缝循环（预加载下一轮）" }
}

struct WallpaperItem: Codable, Equatable {
    var path: String
    var kind: DisplayConfiguration.Kind
}

struct DisplayConfiguration: Codable, Equatable {
    enum Kind: String, Codable { case photo, video }
    var name: String
    var path: String
    var kind: Kind
    var stopped: Bool
    var playlist: [WallpaperItem]? = nil
    var interval: TimeInterval? = nil
    var playlistIndex: Int? = nil
    var rotationEnabled: Bool? = nil
    var effectiveInterval: TimeInterval {
        let value = interval ?? 300
        return value.isFinite ? min(86400, max(10, value)) : 300
    }
    var isRotating: Bool { (playlist?.count ?? 0) > 1 && rotationEnabled != false && !stopped }
    var quality: VideoQuality? = nil
    var loopMode: VideoLoopMode? = nil
    var effectiveQuality: VideoQuality { quality ?? .original }
    var effectiveLoopMode: VideoLoopMode { loopMode ?? .efficient }
    var url: URL { URL(fileURLWithPath: path) }
}

struct DisplayConfigurationStore {
    let url: URL
    private struct Document: Codable {
        var version = 1
        var displays: [String: DisplayConfiguration]
    }

    static var applicationStore: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(url: root.appendingPathComponent("local.tango.macbglive/displays.json"))
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() throws -> [String: DisplayConfiguration] {
        guard exists else { return [:] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else {
            throw NSError(domain: "WallpaperConfiguration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "配置版本不兼容，原文件已保留：\(url.path)"])
        }
        return document.displays
    }

    func save(_ displays: [String: DisplayConfiguration]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(displays: displays))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

struct DisplayTarget {
    let id: String
    let name: String
    let screen: NSScreen

    @MainActor static func connected() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid)! as String
            let size = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
            let primary = screen === NSScreen.screens.first ? " · 主屏" : ""
            return Self(id: id, name: "\(screen.localizedName) · \(size)\(primary)", screen: screen)
        }
    }
}
