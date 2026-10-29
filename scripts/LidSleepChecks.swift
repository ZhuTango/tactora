import Foundation
@main struct LidSleepChecks {
    static func main() {
        for enabled in [true, false] {
            for closed: Bool? in [true, false, nil] {
                for builtIn in [true, false] {
                    for mirrored in [true, false] {
                        let expected = enabled && closed == true && builtIn && !mirrored
                        precondition(LidSleepPolicy.shouldCover(enabled: enabled, closed: closed, builtIn: builtIn, mirrored: mirrored) == expected)
                    }
                }
            }
        }
        print("PASS: blackout policy enabled/lid/unknown/internal/external/mirror combinations")
    }
}
