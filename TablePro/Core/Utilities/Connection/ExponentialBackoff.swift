import Foundation

/// Shared exponential backoff calculator for reconnection delays.
enum ExponentialBackoff {
    private static let seeds: [TimeInterval] = [2, 4, 8]

    /// Calculate delay for a given attempt (1-based).
    /// Sequence: 2s, 4s, 8s, then doubles from last seed, capped at maxDelay.
    static func delay(for attempt: Int, maxDelay: TimeInterval = 120) -> TimeInterval {
        guard attempt > 0 else { return seeds[0] }
        if attempt <= seeds.count {
            return seeds[attempt - 1]
        }
        let lastSeed = seeds[seeds.count - 1]
        let exponent = attempt - seeds.count
        return min(lastSeed * pow(2.0, Double(exponent)), maxDelay)
    }
}
