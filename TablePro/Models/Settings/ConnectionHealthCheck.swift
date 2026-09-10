//
//  ConnectionHealthCheck.swift
//  TablePro
//

import Foundation

/// How often TablePro asks an open connection whether it still works.
///
/// The check is a real query on almost every engine, so a connection nobody is using still costs
/// the server about 2,880 of them a day. That is invisible on a database you own and expensive on
/// one you rent: a serverless compute suspends only after some minutes with no queries, so a
/// steady heartbeat holds it awake and billing around the clock (#2700).
///
/// `onDemand` is the answer for those, and it is not the same as having no answer. TablePro checks
/// the connection the first time it is used after a quiet spell instead, which costs one round
/// trip the user's own action paid for, rather than a stream of them nobody asked for.
internal enum ConnectionHealthCheck: Int, Codable, CaseIterable, Identifiable, Sendable {
    case onDemand = 0
    case every30Seconds = 30
    case every5Minutes = 300
    case every15Minutes = 900

    internal var id: Int { rawValue }

    internal var title: String {
        switch self {
        case .onDemand: return String(localized: "Only when I use the connection")
        case .every30Seconds: return String(localized: "Every 30 seconds")
        case .every5Minutes: return String(localized: "Every 5 minutes")
        case .every15Minutes: return String(localized: "Every 15 minutes")
        }
    }

    /// How long to wait between checks, or nil when nothing is scheduled at all. Nil is why
    /// `onDemand` starts no monitor rather than starting one with a very long interval: a task
    /// that never has anything to do is still a task that wakes up.
    internal var interval: Duration? {
        guard rawValue > 0 else { return nil }
        return .seconds(rawValue)
    }

    /// How recently the connection must have answered for TablePro to take its word for it.
    ///
    /// One value for every setting rather than one per case, because it answers a question the
    /// poll rate has no part in: how long a socket that worked stays worth believing. At the
    /// default it never fires, since a check every 30 seconds keeps the answer far fresher than
    /// this; on the long intervals and on `onDemand` it is what makes the first action after a
    /// quiet spell verify before it runs.
    internal static let freshness: Duration = .seconds(300)

    internal static func isFresh(_ lastVerifiedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastVerifiedAt) < TimeInterval(freshness.components.seconds)
    }
}
