import Foundation
@main struct LidSleepChecks {
    static func main() {
        precondition(LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn: [true]))
        precondition(!LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn: [true, false]))
        precondition(!LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn: [false]))
        precondition(!LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn: []))
        precondition(!LidSleepPolicy.canSleepDisplays(onlineDisplaysBuiltIn: nil))
        var policy = LidSleepPolicy()
        precondition(!policy.update(enabled: false, closed: true))
        precondition(policy.update(enabled: true, closed: true))
        precondition(!policy.update(enabled: true, closed: true))
        precondition(!policy.update(enabled: true, closed: false))
        precondition(policy.update(enabled: true, closed: true))
        precondition(!policy.update(enabled: false, closed: true))
        precondition(!policy.update(enabled: true, closed: nil))
        precondition(policy.update(enabled: true, closed: true))
        print("PASS: lid policy defaults, transitions, deduplication, disabled and unknown states")
    }
}
