import Foundation
import CoreGraphics

enum WindowLayout: String, Codable, CaseIterable {
    case maximize, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight, center, restore, fullscreen

    // AX coordinates: origin at top left of the primary display, y increases down.
    func frame(in area: CGRect, current: CGRect) -> CGRect {
        var result = area
        switch self {
        case .left: result.size.width /= 2
        case .right: result.origin.x += area.width / 2; result.size.width /= 2
        case .top: result.size.height /= 2
        case .bottom: result.origin.y += area.height / 2; result.size.height /= 2
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            result.size = CGSize(width: area.width / 2, height: area.height / 2)
            if self == .topRight || self == .bottomRight { result.origin.x += area.width / 2 }
            if self == .bottomLeft || self == .bottomRight { result.origin.y += area.height / 2 }
        case .center:
            result.size = CGSize(width: min(current.width, area.width), height: min(current.height, area.height))
            result.origin = CGPoint(x: area.midX - result.width / 2, y: area.midY - result.height / 2)
        case .maximize, .restore, .fullscreen: break
        }
        return result.integral
    }
}
