public struct PlaybackPolicy {
    public var userStopped = false
    public var displayAsleep = false
    public var systemAsleep = false
    public var sessionInactive = false
    public var lowPowerMode = false
    public init() {}
    public var shouldPlay: Bool {
        !userStopped && !displayAsleep && !systemAsleep && !sessionInactive && !lowPowerMode
    }
}
