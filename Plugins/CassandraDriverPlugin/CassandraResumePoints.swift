//
//  CassandraResumePoints.swift
//  CassandraDriverPlugin
//

import Foundation

/// Where a browse already walked to, so the next page of the same browse starts from the paging state that ends
/// the last one instead of from the first row.
///
/// The server does not check a paging state against the statement it is given, and one from another statement
/// returns rows from the wrong place without an error, so a point is only ever looked up by the exact statement,
/// values and page size it came from. The states never leave the connection that produced them.
struct CassandraResumePoints {
    static let maximumStatements = 8
    static let maximumPointsPerStatement = 512

    /// The keyspace is part of the key because a browse of an unqualified table reads whichever keyspace the
    /// session is in, and two keyspaces can hold a table of the same name and shape.
    struct Key: Hashable, Sendable {
        let keyspace: String?
        let cql: String
        let values: [String]
        let pageSize: Int
    }

    private var points: [Key: [Int: Data]] = [:]
    private var recency: [Key] = []

    static func pageSize(forLimit limit: Int) -> Int {
        min(max(limit, 100), 5_000)
    }

    static func key(keyspace: String?, cql: String, values: [String], pageSize: Int) -> Key {
        Key(keyspace: keyspace, cql: cql, values: values, pageSize: pageSize)
    }

    func nearest(atOrBefore position: Int, for key: Key) -> (position: Int, token: Data)? {
        guard let recorded = points[key],
              let best = recorded.keys.filter({ $0 <= position }).max(),
              let token = recorded[best]
        else { return nil }
        return (best, token)
    }

    /// A point is recorded by the walk that just read up to it, so the points past it came from an earlier walk
    /// over rows that may have changed since, and are dropped rather than mixed with the new ones.
    mutating func record(_ token: Data, at position: Int, for key: Key) {
        guard !token.isEmpty else { return }
        recency.removeAll { $0 == key }
        recency.append(key)
        var recorded = (points[key] ?? [:]).filter { $0.key <= position }
        if recorded.count >= Self.maximumPointsPerStatement, recorded[position] == nil,
           let farthest = recorded.keys.max() {
            recorded.removeValue(forKey: farthest)
        }
        recorded[position] = token
        points[key] = recorded
        while recency.count > Self.maximumStatements {
            points.removeValue(forKey: recency.removeFirst())
        }
    }

    mutating func remove(_ key: Key) {
        points.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    mutating func removeAll() {
        points.removeAll()
        recency.removeAll()
    }
}

/// One browse's walk: the statement, its page size, and the key its resume points are kept under.
struct CassandraBrowseWalk {
    let browse: CassandraBrowseStatement
    let pageSize: Int
    let key: CassandraResumePoints.Key
}

/// Stops a browse walk between pages. The walk runs inside the connection actor while the driver blocks on each
/// page, so the stop request has to reach it from outside the actor.
final class CassandraCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private let consumerLeft: @Sendable () -> Bool

    init(consumerLeft: @escaping @Sendable () -> Bool = { false }) {
        self.consumerLeft = consumerLeft
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled || Task.isCancelled || consumerLeft() {
            throw CancellationError()
        }
    }
}
