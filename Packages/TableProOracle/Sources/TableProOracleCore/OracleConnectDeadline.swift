import Foundation

public struct OracleConnectDeadline: Sendable {
    private let expiration: ContinuousClock.Instant

    public init(seconds: Double) {
        self.init(seconds: seconds, now: .now)
    }

    init(seconds: Double, now: ContinuousClock.Instant) {
        let finiteSeconds = seconds.isFinite ? max(0, seconds) : 0
        let boundedSeconds = min(finiteSeconds, Double(Int32.max))
        let milliseconds = Int64((boundedSeconds * 1_000).rounded(.up))
        expiration = now.advanced(by: .milliseconds(milliseconds))
    }

    public func remainingSeconds() -> Double {
        remainingSeconds(at: .now)
    }

    func remainingSeconds(at now: ContinuousClock.Instant) -> Double {
        guard now < expiration else { return 0 }
        let components = now.duration(to: expiration).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
