import AppKit

final class IdleFanHardware: FanHardware {
    func sample(requiredKeys: [String]?) throws -> FanSnapshot { fatalError("Idle helper must not sample hardware") }
    func set(_ fan: FanReading, rpm: Double) throws { fatalError("Idle helper must not control hardware") }
    func restore(_ ids: [Int]) throws { fatalError("No owned fans") }
}

@main struct FanServiceChecks {
    @MainActor static func main() {
        let service = FanService(engine: FanEngine(hardware: IdleFanHardware(), saveOwned: { _ in }))
        // Signature validation and launchd delivery can outlive the first timer tick.
        withExtendedLifetime(service) {
            RunLoop.main.run(until: Date().addingTimeInterval(2.2))
            print("Delayed first connection survives helper startup")
        }
    }
}
