import Foundation
import IOKit

struct FanSMCError: LocalizedError {
    let key: String
    let result: kern_return_t
    let code: UInt8
    var errorDescription: String? { "SMC \(key) 操作失败（\(result)/\(code)）。" }
}

struct FanSMCValue {
    let type: String
    var bytes: [UInt8]
    var number: Double? {
        switch (type, bytes.count) {
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case ("ui8 ", 1): return Double(bytes[0])
        case ("ui16", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case ("fpe2", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }
}

/// AppleSMC's 80-byte user-client ABI. Explicit offsets avoid Swift struct padding differences.
final class FanSMC {
    private var connection: io_connect_t = 0
    init() throws {
        #if !arch(arm64)
        throw FanControlError(message: "风扇温控仅支持 Apple Silicon。")
        #else
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanControlError(message: "未找到 AppleSMC。") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw FanControlError(message: "无法读取温度：\(result)") }
        #endif
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(key: String, command: UInt8, size: Int = 0, bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.utf8.count == 4, size <= 32, bytes.count <= 32 else { throw FanControlError(message: "无效 SMC 请求。") }
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        for i in 0..<4 { input[i] = UInt8(truncatingIfNeeded: code >> (i * 8)); input[28+i] = UInt8(truncatingIfNeeded: size >> (i * 8)) }
        input[42] = command
        for (i, byte) in bytes.enumerated() { input[48+i] = byte }
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else {
            throw FanSMCError(key: key, result: result, code: output[40])
        }
        return output
    }
    func hasKey(_ key: String) throws -> Bool {
        do { _ = try call(key: key, command: 9); return true }
        catch let error as FanSMCError where error.result == KERN_SUCCESS && error.code == 132 { return false }
    }
    func read(_ key: String) throws -> FanSMCValue {
        let info = try call(key: key, command: 9)
        let size = (0..<4).reduce(0) { $0 | Int(info[28+$1]) << ($1 * 8) }
        guard (1...32).contains(size) else { throw FanControlError(message: "未知 SMC 数据长度。") }
        let type = String(bytes: info[32..<36].reversed(), encoding: .ascii) ?? ""
        let output = try call(key: key, command: 5, size: size)
        return FanSMCValue(type: type, bytes: Array(output[48..<(48+size)]))
    }
    func number(_ key: String) throws -> Double {
        guard let value = try read(key).number else { throw FanControlError(message: "不支持的传感器格式：\(key)") }
        return value
    }
    // Internal to the helper's native hardware adapter. Not exposed over IPC.
    func write(_ key: String, bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw FanControlError(message: "控速需要授权辅助服务。") }
        let existing = try read(key)
        guard existing.bytes.count == bytes.count else { throw FanControlError(message: "SMC 数据长度不匹配。") }
        _ = try call(key: key, command: 6, size: bytes.count, bytes: bytes)
    }
    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }
    func snapshot(requiredKeys: [String]? = nil) throws -> FanSnapshot {
        let chip = Self.chipName()
        let candidates = FanSensorMap.keys(chip: chip)
        guard !candidates.isEmpty else { throw FanControlError(message: "尚未验证 \(chip) 的核心温度接口，暂不可启用。") }
        let keys = try requiredKeys ?? candidates.filter { try hasKey($0) }
        guard !keys.isEmpty else { throw FanControlError(message: "未识别到 CPU 核心温度。") }
        var temperatures: [String: Double] = [:]
        for key in keys {
            let value = try number(key)
            guard (1...125).contains(value) else { throw FanControlError(message: "核心温度无效：\(key)") }
            temperatures[key] = value
        }
        let count = try number("FNum")
        guard count.rounded() == count, (1...8).contains(count) else { throw FanControlError(message: "此设备没有可控制的风扇。") }
        let fans = try (0..<Int(count)).map { id -> FanReading in
            let prefix = "F\(id)"
            let modeKey = (try? read(prefix + "md")) != nil ? prefix + "md" : prefix + "Md"
            let mode = try read(modeKey)
            let target = try read(prefix + "Tg")
            guard mode.type == "ui8 ", mode.bytes.count == 1, target.type == "flt ", target.bytes.count == 4 else {
                throw FanControlError(message: "尚不支持此机型的风扇控制格式。")
            }
            let minimum = try number(prefix + "Mn"), maximum = try number(prefix + "Mx")
            let actual = try number(prefix + "Ac"), targetRPM = try number(prefix + "Tg")
            guard minimum > 0, maximum > minimum, maximum <= 20000, actual >= 0, actual <= maximum * 1.2,
                  [0,1,3].contains(Int(mode.bytes[0])) else { throw FanControlError(message: "风扇状态或转速边界无效。") }
            return FanReading(id: id, minimum: minimum, maximum: maximum, actual: actual, target: targetRPM, mode: Int(mode.bytes[0]), modeKey: modeKey)
        }
        return FanSnapshot(chip: chip, temperatures: temperatures, fans: fans, message: fans.contains { $0.mode == 1 } ? "当前处于手动控速模式" : "系统自动控制")
    }
}

final class NativeFanHardware: FanHardware {
    private let smc: FanSMC
    init() throws { smc = try FanSMC() }
    func sample(requiredKeys: [String]?) throws -> FanSnapshot { try smc.snapshot(requiredKeys: requiredKeys) }
    private func floatBytes(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
    }
    func set(_ fan: FanReading, rpm: Double) throws {
        guard (0...7).contains(fan.id), rpm.isFinite, rpm >= fan.minimum, rpm <= fan.maximum else {
            throw FanControlError(message: "无效风扇目标。")
        }
        // Never disable thermalmonitord / write Ftst to bypass the system's thermal management.
        if try smc.number(fan.modeKey) != 1 { try smc.write(fan.modeKey, bytes: [1]) }
        try smc.write("F\(fan.id)Tg", bytes: floatBytes(rpm))
        guard try smc.number(fan.modeKey) == 1, abs(try smc.number("F\(fan.id)Tg") - rpm) <= 2 else {
            throw FanControlError(message: "风扇未接受目标转速，正在恢复系统控制。")
        }
    }
    func restore(_ ids: [Int]) throws {
        var failures: [String] = []
        for id in ids {
            do {
                guard (0...7).contains(id) else { throw FanControlError(message: "无效恢复目标。") }
                let modeKey = (try? smc.read("F\(id)md")) != nil ? "F\(id)md" : "F\(id)Md"
                try smc.write(modeKey, bytes: [0])
                try smc.write("F\(id)Tg", bytes: floatBytes(0))
                guard [0,3].contains(try smc.number(modeKey)) else { throw FanControlError(message: "自动模式读回失败。") }
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw FanControlError(message: failures.joined(separator: "；")) }
    }
}
