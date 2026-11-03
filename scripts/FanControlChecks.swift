import Foundation
@main struct FanControlChecks {
 static func main() throws {
  precondition(FanCurve().low == 50 && FanCurve().high == 80)
  let fan = FanReading(id:0, minimum:1500, maximum:5500, actual:1500, target:1500, mode:0, modeKey:"F0Md")
  var mode: Double = 0, target: Double = 1500
  var waits = 0, writes: [String] = []
  try confirmFanTarget(fan, rpm:3000, read: { $0 == "F0Md" ? mode : target }, write: { key, _ in
   writes.append(key)
   if key == "F0Tg" { precondition(mode == 1, "Confirm mode before writing target") }
  }, pause: { waits += 1; if waits == 2 { mode = 1 }; if waits == 4 { target = 3000 } })
  precondition(waits == 4 && writes == ["F0Md", "F0Tg"])
  waits = 0; writes = []
  do {
   try confirmFanTarget(fan, rpm:3000, read: { _ in 0 }, write: { key, _ in writes.append(key) }, pause: { waits += 1 })
   preconditionFailure("Unaccepted mode must fail")
  } catch {}
  precondition(waits == 10 && writes == ["F0Md"], "Do not write target when mode fails")
  let curve = FanCurve(low: 50, high: 85)
  precondition(curve.valid)
  precondition(!FanCurve(low: 80, high: 85).valid)
  precondition(!FanCurve(low: .nan, high: 85).valid)
  precondition(curve.rpm(temperature: 30, minimum: 1200, maximum: 5400) == 1200)
  precondition(curve.rpm(temperature: 67.5, minimum: 1200, maximum: 5400) == 3300)
  precondition(curve.rpm(temperature: 100, minimum: 1200, maximum: 5400) == 5400)
  var filter = FanTemperatureFilter()
  precondition(filter.update(80, now: 0) == 80)
  precondition(filter.update(79, now: 2) == 80)
  precondition(filter.update(70, now: 4) == 80)
  precondition(filter.update(70, now: 12) == 80)
  precondition(filter.update(70, now: 14) == 70)
  precondition(filter.update(90, now: 15) == 90)
  precondition(FanSMCValue(type: "flt ", bytes: [0,0,72,66]).number == 50)
  precondition(FanSMCValue(type: "flt ", bytes: [0]).number == nil)
  precondition(FanSMCValue(type: "ui8 ", bytes: [0]).number == 0)
  precondition(FanSensorMap.keys(chip: "Intel Core i9").isEmpty)
  precondition(!FanSensorMap.keys(chip: "Apple M1 Max").isEmpty)
  for generation in 1...5 { precondition(!FanSensorMap.keys(chip: "Apple M\(generation) Max").isEmpty) }
  precondition(FanSensorMap.keys(chip: "Apple M99 Max").isEmpty)
  let defaults = UserDefaults(suiteName: "tactora-fan-tests")!
  defaults.removePersistentDomain(forName: "tactora-fan-tests")
  precondition(!ToolFeature.fans.isEnabled(in: defaults))
  precondition(ToolFeature.calendar.isEnabled(in: defaults))
  print("Fan curve, hysteresis, decoding and feature-default checks passed")
 }
}
