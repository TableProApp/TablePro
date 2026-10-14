import Foundation

public enum ExponentialBackoff {
    private static let seeds: [TimeInterval] = [2, 4, 8]

    public static func delay(for attempt: Int, maxDelay: TimeInterval = 120) -> TimeInterval {
        guard attempt > 0 else { return seeds[0] }
        if attempt <= seeds.count {
            return seeds[attempt - 1]
        }
        let lastSeed = seeds[seeds.count - 1]
        let exponent = attempt - seeds.count
        return min(lastSeed * pow(2.0, Double(exponent)), maxDelay)
    }
}
