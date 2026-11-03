import Foundation

struct FanControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct FanCurve: Codable, Equatable {
    var low: Double = 50
    var high: Double = 80
    var valid: Bool { low.isFinite && high.isFinite && low >= 40 && high <= 95 && high - low >= 10 }
    func rpm(temperature: Double, minimum: Double, maximum: Double) -> Double {
        minimum + (maximum - minimum) * min(1, max(0, (temperature - low) / (high - low)))
    }
}
struct FanTemperatureFilter {
    private var held: Double?
    private var coolingSince: TimeInterval?
    mutating func update(_ temperature: Double, now: TimeInterval) -> Double {
        guard let current = held else { held = temperature; return temperature }
        if temperature >= current { held = temperature; coolingSince = nil }
        else if current - temperature >= 3 {
            if coolingSince == nil { coolingSince = now }
            if now - coolingSince! >= 10 { held = temperature; coolingSince = nil }
        } else { coolingSince = nil }
        return held!
    }
}
struct FanReading: Codable {
    var id: Int
    var minimum: Double
    var maximum: Double
    var actual: Double
    var target: Double
    var mode: Int
    var modeKey: String
}
struct FanSnapshot: Codable {
    var chip: String
    var temperatures: [String: Double]
    var fans: [FanReading]
    var active: Bool = false
    var message: String = "系统自动控制"
    var maximumTemperature: Double? { temperatures.values.max() }
}

// CPU sensor identities cross-checked against Stats' public sensor catalog.
// Only known CPU keys are used; unknown chips never inherit a prior generation's map.
enum FanSensorMap {
    static func keys(chip: String) -> [String] {
        let generation = chip.split(separator: " ").first { $0.first == "M" }.map(String.init)
        switch generation {
        case "M1": return ["Tp09","Tp0T","Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b"]
        case "M2": return ["Tp1h","Tp1t","Tp1p","Tp1l","Tp01","Tp05","Tp09","Tp0D","Tp0X","Tp0b","Tp0f","Tp0j"]
        case "M3": return ["Te05","Te0L","Te0P","Te0S","Tf04","Tf09","Tf0A","Tf0B","Tf0D","Tf0E","Tf44","Tf49","Tf4A","Tf4B","Tf4D","Tf4E"]
        case "M4": return ["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"]
        case "M5": return ["Tp00","Tp04","Tp08","Tp0C","Tp0G","Tp0K","Tp0O","Tp0R","Tp0U","Tp0X","Tp0a","Tp0d","Tp0g","Tp0j","Tp0m","Tp0p","Tp0u","Tp0y"]
        default: return []
        }
    }
}

protocol FanHardware: AnyObject {
    func sample(requiredKeys: [String]?) throws -> FanSnapshot
    func set(_ fan: FanReading, rpm: Double) throws
    func restore(_ ids: [Int]) throws
}
/// Single-queue controller. The lease is independent of the UI and never renewed by its own timer.
final class FanEngine {
    private let hardware: FanHardware
    private let saveOwned: ([Int]) throws -> Void
    private var owned: [Int]
    private var keys: [String] = []
    private var curve = FanCurve()
    private var filter = FanTemperatureFilter()
    private var heartbeat: TimeInterval = 0
    private var responseSince: [Int: TimeInterval] = [:]
    private(set) var active = false
    private(set) var message = "系统自动控制"
    private(set) var snapshot: FanSnapshot?
    var recoveryPending: Bool { !active && !owned.isEmpty }
    init(hardware: FanHardware, owned: [Int] = [], saveOwned: @escaping ([Int]) throws -> Void) {
        self.hardware = hardware; self.owned = owned; self.saveOwned = saveOwned
        if !owned.isEmpty { stop(reason: "恢复上次中断的温控会话") }
    }
    func enable(curve: FanCurve, now: TimeInterval) throws {
        guard curve.valid else { throw FanControlError(message: "温度需在 40–95°C 之间，且至少相差 10°C。") }
        guard !recoveryPending else { throw FanControlError(message: "仍在恢复系统控制，请稍后再试。") }
        if active { self.curve = curve; heartbeat = now; return }
        let initial = try hardware.sample(requiredKeys: nil)
        guard initial.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) else {
            throw FanControlError(message: "风扇已处于手动模式，请先在其他控速软件中恢复自动模式并退出。")
        }
        let ids = initial.fans.map(\.id)
        try saveOwned(ids) // Journal before the first hardware mutation.
        owned = ids; keys = initial.temperatures.keys.sorted(); self.curve = curve
        filter = FanTemperatureFilter(); responseSince = [:]; heartbeat = now; active = true
        do { try apply(now: now) }
        catch { stop(reason: error.localizedDescription); throw error }
    }
    func renew(now: TimeInterval) { if active { heartbeat = now } }
    func tick(now: TimeInterval, thermalOK: Bool) {
        if recoveryPending { stop(reason: message); return }
        guard active else { return }
        guard now - heartbeat < 6, now >= heartbeat else { stop(reason: "温控连接超时，已请求恢复系统自动控制。"); return }
        guard thermalOK else { stop(reason: "系统热压力升高，已请求恢复系统自动控制。"); return }
        do { try apply(now: now) } catch { stop(reason: error.localizedDescription) }
    }
    private func apply(now: TimeInterval) throws {
        let value = try hardware.sample(requiredKeys: keys)
        guard Set(value.temperatures.keys) == Set(keys), !keys.isEmpty,
              value.temperatures.values.allSatisfy({ $0.isFinite && (1...125).contains($0) }),
              value.fans.map(\.id) == owned,
              let maximum = value.maximumTemperature else { throw FanControlError(message: "传感器覆盖或风扇状态发生变化。") }
        let temperature = filter.update(maximum, now: now)
        for fan in value.fans {
            guard fan.minimum > 0, fan.maximum > fan.minimum, fan.maximum <= 20000 else { throw FanControlError(message: "无效风扇转速范围。") }
            let target = curve.rpm(temperature: temperature, minimum: fan.minimum, maximum: fan.maximum).rounded()
            if abs(fan.actual - target) > max(300, target * 0.2) {
                if responseSince[fan.id] == nil { responseSince[fan.id] = now }
                if now - responseSince[fan.id]! >= 20 {
                    throw FanControlError(message: "风扇 \(fan.id + 1) 未在 20 秒内响应目标转速。")
                }
            } else { responseSince[fan.id] = nil }
            try hardware.set(fan, rpm: target)
        }
        snapshot = try hardware.sample(requiredKeys: keys)
        snapshot?.active = true; message = "正在按 CPU 核心最高温度调速"; snapshot?.message = message
    }
    func stop(reason: String) {
        if active { NSLog("Tactora fan control stopped: %@", reason) }
        active = false; snapshot?.active = false
        guard !owned.isEmpty else { message = reason; return }
        do {
            try hardware.restore(owned)
            try saveOwned([])
            owned = []; message = reason + " · 已恢复系统自动控制"
        } catch { message = "恢复系统控制失败，正在重试：" + error.localizedDescription }
        snapshot?.message = message
    }
}
