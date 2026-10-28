import Foundation
@main struct LidSleepChecks {
    static func main() {
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
