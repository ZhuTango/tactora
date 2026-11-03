import Foundation
@main struct FanControlChecks {
 static func main() throws {
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
