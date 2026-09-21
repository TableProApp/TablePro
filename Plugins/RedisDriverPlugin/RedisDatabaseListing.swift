//
//  RedisDatabaseListing.swift
//  RedisDriverPlugin
//
//  How many numbered databases a server has, and how many keys each holds, for the sidebar and
//  the database list. Both lists go through here so they cannot disagree about the count.
//

import Foundation

enum RedisDatabaseCount {
    static let assumed = 16
    static let limit = RedisDatabaseIndex.selectable.count

    static func reported(by reply: RedisReply) -> Int? {
        guard let pair = reply.arrayValue, pair.count >= 2, let count = pair[1].intValue,
              (1 ... limit).contains(count) else { return nil }
        return count
    }

    /// Without the server's own answer the count is at least Redis's default of 16, and at least
    /// one past every database known to exist: one `INFO keyspace` names because it holds keys,
    /// and the one the session is on. Azure allows 64 databases and Memorystore 100, both with
    /// `CONFIG` refused, so a flat 16 would hide a populated `db20`.
    static func resolve(reported: Int?, keyspace: [Int: Int]?, currentDatabase: Int) -> Int {
        if let reported { return reported }
        let known = (keyspace.map { Array($0.keys) } ?? []) + [currentDatabase]
        let highest = known.filter { (0 ..< limit).contains($0) }.max() ?? 0
        return max(assumed, highest + 1)
    }

    /// The databases a cluster serves, from each primary's `CONFIG GET cluster-databases`: the
    /// fewest any primary reports, since a database one primary lacks cannot hold the keys that
    /// hash to it. Redis answers an empty list and a declined read answers nil, neither of which
    /// says anything, so a cluster no primary vouches for serves database 0 alone.
    static func servedByCluster(primaryReplies: [RedisReply?]) -> Int {
        primaryReplies.compactMap { $0.flatMap(reported(by:)) }.min() ?? 1
    }
}

struct RedisDatabaseListing: Equatable, Sendable {
    let databaseCount: Int
    /// Nil when the server declined `INFO keyspace`, which leaves every count unknown rather
    /// than zero.
    let keyCounts: [Int: Int]?

    func keyCount(forDatabase index: Int) -> Int? {
        guard let keyCounts else { return nil }
        return keyCounts[index] ?? 0
    }
}

extension RedisCommandChannel {
    /// `INFO keyspace` is read when key counts are wanted, and when the server would not say how
    /// many databases it has, because then the keyspace is what can widen the count.
    func databaseListing(includingKeyCounts: Bool) async throws -> RedisDatabaseListing {
        guard supportsDatabaseSelection else {
            return RedisDatabaseListing(
                databaseCount: 1,
                keyCounts: includingKeyCounts ? try await keyCountsByDatabase() : nil
            )
        }
        let reported = try await reportedDatabaseCount()
        let keyCounts = includingKeyCounts || reported == nil ? try await keyCountsByDatabase() : nil
        let count = RedisDatabaseCount.resolve(
            reported: reported,
            keyspace: keyCounts,
            currentDatabase: currentDatabase()
        )
        return RedisDatabaseListing(databaseCount: count, keyCounts: includingKeyCounts ? keyCounts : nil)
    }

    func reportedDatabaseCount() async throws -> Int? {
        try await runMetadataRead(["CONFIG", "GET", "databases"]).flatMap(RedisDatabaseCount.reported(by:))
    }

    /// Nil when the server declines, which an ACL user outside `@dangerous` is for `INFO`. A
    /// server with one database counts it with `DBSIZE`, which a cluster sends to every primary
    /// and adds up, and which is nil when any of them declines.
    func keyCountsByDatabase() async throws -> [Int: Int]? {
        guard supportsDatabaseSelection else { return try await databaseZeroKeyCounts() }
        return try await keyspaceKeyCounts()
    }

    func databaseZeroKeyCounts() async throws -> [Int: Int]? {
        try await runMetadataRead(["DBSIZE"])?.intValue.map { [0: $0] }
    }

    /// `INFO keyspace` describes the server that answers it, one line per database holding keys.
    func keyspaceKeyCounts() async throws -> [Int: Int]? {
        guard let reply = try await runMetadataRead(["INFO", "keyspace"]) else { return nil }
        return RedisServerInfo.keyspace(from: reply.stringValue ?? "")
    }
}
