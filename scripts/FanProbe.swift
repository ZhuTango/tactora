import Foundation
@main struct FanProbe {
 static func main() throws {
  let smc = try FanSMC()
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  print(String(data: try encoder.encode(smc.snapshot()), encoding: .utf8)!)
  for key in ["Ftst", "F0Md", "F0md", "F0Tg"] {
   if let value = try? smc.read(key) { print("\(key): \(value.type), \(value.bytes)") }
  }
 }
}
