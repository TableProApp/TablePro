//
//  CassandraCellLifetime.swift
//  TableProCassandraCore
//

import Foundation

// A write resets the TTL of every cell it writes to its own USING TTL, or to the table's default without one, so an
// edit has to carry what each cell had left when it was read.
public enum CassandraCellLifetime: Hashable, Sendable {
    case expiring(seconds: Int)
    case permanent

    // Nil for a cell read as null, whose edit is written without a TTL as before.
    public init?(valueIsNull: Bool, timeToLive: String?) {
        guard !valueIsNull else { return nil }
        guard let timeToLive else {
            self = .permanent
            return
        }
        guard let seconds = Int(timeToLive), seconds > 0 else { return nil }
        self = .expiring(seconds: seconds)
    }

    public static func remaining(seconds: Int, after elapsed: Duration) -> Int {
        max(1, seconds - Int(max(elapsed.components.seconds, 0)))
    }
}

// The lifetimes of one row's cells as a browse read them, with what the table says about naming the row.
public struct CassandraRowLifetimes: Sendable, Equatable {
    public let columns: [String]
    public let lifetimes: [CassandraCellLifetime?]
    public let readAt: ContinuousClock.Instant
    public let layout: CassandraTableLayout

    // Nil when every cell would be written the way a write without USING writes it, so nothing is kept for the row.
    public init?(
        columns: [String],
        lifetimes: [CassandraCellLifetime?],
        readAt: ContinuousClock.Instant,
        layout: CassandraTableLayout
    ) {
        guard columns.count == lifetimes.count else { return nil }
        let changesAWrite = lifetimes.contains { lifetime in
            switch lifetime {
            case .expiring: return true
            case .permanent: return layout.defaultTimeToLive != 0
            case nil: return false
            }
        }
        guard changesAWrite else { return nil }
        self.columns = columns
        self.lifetimes = lifetimes
        self.readAt = readAt
        self.layout = layout
    }

    // A cell whose TTL ran out since the read is gone from the server, so an edit of it would live for one second.
    public func hasExpired(_ column: String, at now: ContinuousClock.Instant) -> Bool {
        guard let index = columns.firstIndex(of: column), case .expiring(let seconds) = lifetimes[index] else {
            return false
        }
        return readAt.duration(to: now) >= .seconds(seconds)
    }

    // The USING TTL a write of `column` keeps the cell's lifetime with, or nil for none. A cell that never expired
    // is written with 0 unless the table's default TTL is 0, where a write without USING keeps it the same.
    public func timeToLive(of column: String, at now: ContinuousClock.Instant) -> Int? {
        guard let index = columns.firstIndex(of: column), let lifetime = lifetimes[index] else { return nil }
        switch lifetime {
        case .expiring(let seconds):
            return CassandraCellLifetime.remaining(seconds: seconds, after: readAt.duration(to: now))
        case .permanent:
            return layout.defaultTimeToLive == 0 ? nil : 0
        }
    }
}
