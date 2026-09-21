//
//  RedisDatabaseCount.swift
//  RedisDriverPlugin
//
//  How many logical databases the sidebar lists.
//  Kept apart from the driver, which imports CRedis, so the rule can be tested without the
//  C library.
//

import Foundation

nonisolated enum RedisDatabaseCount {
    /// What a Redis server ships with, and what the sidebar draws when the server will not say.
    static let fallback = 16

    /// A cluster node answers `CONFIG GET databases` with 1, and refuses `SELECT` with any other
    /// index, so the tree shows the one keyspace that exists rather than fifteen that do not.
    static let cluster = 1

    /// Managed Redis commonly removes `CONFIG` outright rather than denying it: AWS ElastiCache
    /// lists it as restricted, so the probe answers `unknown command` and `run` throws. The count
    /// only decides how many `db` entries to draw, so a server that will not answer takes the
    /// fallback instead of failing the whole listing.
    static func resolve(on conn: any RedisCommandChannel) async -> Int {
        guard conn.supportsDatabaseSelection else { return cluster }
        guard let reply = try? await conn.run(["CONFIG", "GET", "databases"]),
              let array = reply.arrayValue,
              array.count >= 2,
              let count = array[1].intValue,
              count > 0
        else {
            return fallback
        }
        return count
    }
}
