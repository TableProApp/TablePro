import Foundation

// Every check is a real query, so a steady heartbeat keeps a serverless database awake and billing (#2700).
internal enum ConnectionHealthCheck: Int, Codable, CaseIterable, Identifiable, Sendable {
    case onDemand = 0
    case every30Seconds = 30
    case every5Minutes = 300
    case every15Minutes = 900

    internal var id: Int { rawValue }

    internal var title: String {
        switch self {
        case .onDemand: return String(localized: "Only when used")
        case .every30Seconds: return String(localized: "Every 30 seconds")
        case .every5Minutes: return String(localized: "Every 5 minutes")
        case .every15Minutes: return String(localized: "Every 15 minutes")
        }
    }

    // Nil starts no monitor at all, rather than one with a long interval that still wakes up.
    internal var interval: Duration? {
        guard rawValue > 0 else { return nil }
        return .seconds(rawValue)
    }

    // How long an answer stays believable whatever the poll rate; on long intervals and on demand it makes
    // the first action after a quiet spell verify before it runs.
    internal static let freshness: Duration = .seconds(300)

    internal static func isFresh(_ lastVerifiedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastVerifiedAt) < TimeInterval(freshness.components.seconds)
    }
}
