import Foundation
final class Hardware: FanHardware {
 var modes = [0,0]; var failWrite = false; var failRestore = false; var failSensor = false
 var actual: Double = 3000
 var written: [Double] = []; var restores = 0
 func sample(requiredKeys: [String]?) throws -> FanSnapshot {
  if failSensor { throw FanControlError(message: "sensor lost") }
  return FanSnapshot(chip: "Apple M1 Max", temperatures: ["Tp01":75], fans: (0..<2).map { FanReading(id:$0, minimum:1500, maximum:5500, actual:actual, target:3000, mode:modes[$0], modeKey:"F\($0)Md") })
 }
 func set(_ fan: FanReading, rpm: Double) throws { modes[fan.id] = 1; if failWrite && fan.id == 1 { throw FanControlError(message:"write failed") }; written.append(rpm) }
 func restore(_ ids: [Int]) throws { restores += 1; if failRestore { throw FanControlError(message:"restore failed") }; for id in ids { modes[id] = 0 } }
}
@main struct FanEngineChecks {
 static func main() throws {
  let hw = Hardware(); var saved: [Int] = []
  let engine = FanEngine(hardware: hw, saveOwned: { saved = $0 })
  try engine.enable(curve: FanCurve(), now: 0)
  precondition(engine.active && saved == [0,1])
  engine.tick(now: 7, thermalOK: true)
  precondition(!engine.active && hw.modes == [0,0] && saved.isEmpty)
  hw.failWrite = true
  do { try engine.enable(curve: FanCurve(), now: 10); preconditionFailure("expected partial failure") } catch {}
  precondition(hw.modes == [0,0] && saved.isEmpty)
  hw.failWrite = false
  try engine.enable(curve: FanCurve(), now: 20)
  hw.failRestore = true; engine.stop(reason: "stop")
  precondition(!saved.isEmpty && engine.recoveryPending)
  hw.failRestore = false; engine.tick(now: 21, thermalOK: true)
  precondition(saved.isEmpty && !engine.recoveryPending)
  try engine.enable(curve: FanCurve(), now: 30)
  hw.failSensor = true; engine.tick(now: 32, thermalOK: true)
  precondition(!engine.active && hw.modes == [0,0])
  hw.failSensor = false
  try engine.enable(curve: FanCurve(), now: 40)
  engine.tick(now: 41, thermalOK: false)
  precondition(!engine.active && hw.modes == [0,0])
  hw.actual = 0
  try engine.enable(curve: FanCurve(), now: 50)
  engine.renew(now: 69); engine.tick(now: 69, thermalOK: true)
  precondition(engine.active, "Allow spin-up")
  engine.renew(now: 71); engine.tick(now: 71, thermalOK: true)
  precondition(!engine.active && hw.modes == [0,0], "Stalled fan must restore system mode")
  hw.modes = [1,1]
  do { try engine.enable(curve: FanCurve(), now: 50); preconditionFailure("must not steal") } catch {}
  precondition(hw.modes == [1,1])
  print("Fan lease, partial-write rollback, recovery retry, sensor failure, thermal pressure and ownership checks passed")
 }
}
