//
//  RedisPluginDriver+Scan.swift
//  RedisDriverPlugin
//

import Foundation
import OSLog
import TableProPluginKit
import TableProRedisCore

extension RedisPluginDriver {
    // A wider COUNT holds the server longer per call, so it grows only as far as the keys the caller keeps.
    static func scanCount(forKeysWanted maxKeys: Int) -> Int {
        min(max(maxKeys, 1_000), maxKeyBrowseScan)
    }

    func scanAllKeys(
        connection conn: any RedisCommandChannel,
        pattern: String?,
        typeFilter: String? = nil,
        maxKeys: Int
    ) async throws -> [String] {
        var allKeys: [String] = []
        var cursor = RedisClusterCursor.start
        let count = Self.scanCount(forKeysWanted: maxKeys)

        repeat {
            try Task.checkCancellation()
            let page = try await conn.scanKeyspace(
                cursor: cursor, pattern: pattern, type: typeFilter, count: count, scope: .outsideBlock
            )
            cursor = page.cursor
            allKeys.append(contentsOf: page.keys)
            if allKeys.count >= maxKeys {
                return Array(allKeys.prefix(maxKeys)).sorted()
            }
        } while cursor != RedisClusterCursor.start

        return allKeys.sorted()
    }

    /// A page continues the walk its scope saved, from the SCAN cursor where the last page stopped, and paints as soon
    /// as the replies hold its keys. The first page and the page on screen asked for again start over.
    /// A browse that asks for every key at once still stops at `maxKeyBrowseScan` and says so.
    func executeKeyBrowse(
        pattern: String?,
        typeScope: String?,
        limit: Int,
        offset: Int,
        connection conn: any RedisCommandChannel,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard limit > 0 else {
            return try await executeWholeKeyBrowse(
                pattern: pattern, typeScope: typeScope, offset: offset, connection: conn, startTime: startTime
            )
        }
        // A `KEYBROWSE DB n` reads inside a visit to n, which a cluster's next-command database does not report.
        let database = RedisDatabaseVisit.database ?? conn.databaseForNextCommand()
        let scope = RedisKeyBrowseWalk.Scope(database: database, pattern: pattern, type: typeScope)
        var walk = savedKeyBrowseWalk(for: scope).flatMap { $0.continues(atOffset: offset) ? $0 : nil }
            ?? RedisKeyBrowseWalk(scope: scope)
        let (sum, overflowed) = max(0, offset).addingReportingOverflow(limit)
        let end = overflowed ? Int.max : sum
        while walk.needsKeys(through: end) {
            try Task.checkCancellation()
            let page = try await conn.scanKeyspace(
                cursor: walk.cursor, pattern: pattern, type: typeScope,
                count: Self.scanCount(forKeysWanted: end - walk.keys.count), scope: .outsideBlock
            )
            walk.absorb(keys: page.keys, nextCursor: page.cursor)
        }
        walk.finishLoad()
        walk.servedOffset = offset
        saveKeyBrowseWalk(walk)

        return try await buildKeyBrowseResult(
            keys: walk.page(offset: offset, limit: limit), connection: conn, startTime: startTime,
            statusMessage: walk.isComplete ? nil : String(localized: "Sorted within the keys loaded so far")
        )
    }

    private func executeWholeKeyBrowse(
        pattern: String?,
        typeScope: String?,
        offset: Int,
        connection conn: any RedisCommandChannel,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let scanCap = RedisPluginDriver.maxKeyBrowseScan
        let rawKeys = try await scanAllKeys(
            connection: conn,
            pattern: pattern,
            typeFilter: typeScope,
            maxKeys: scanCap
        )
        var seen = Set<String>()
        let matchedKeys = rawKeys.filter { seen.insert($0).inserted }
        let pageKeys = Array(matchedKeys[min(max(0, offset), matchedKeys.count)...])
        return try await buildKeyBrowseResult(
            keys: pageKeys, connection: conn, startTime: startTime, isTruncated: rawKeys.count >= scanCap
        )
    }

    func executeKeyTree(
        pattern: String?,
        limit: Int,
        connection conn: any RedisCommandChannel,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let keys = try await scanAllKeys(
            connection: conn, pattern: pattern, maxKeys: limit
        )
        return try await buildKeyTreeResult(
            keys: keys, connection: conn, startTime: startTime, isTruncated: keys.count >= limit
        )
    }

    func buildScanPageResult(
        _ page: RedisKeyspacePage,
        connection conn: any RedisCommandChannel,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let outcome = RedisScanPageOutcome(page: page, rowLimit: PluginRowLimits.emergencyMax)
        // SCAN COUNT is the user's to set, so a page can hold any number of keys.
        return try await buildKeyBrowseResult(
            keys: outcome.keys,
            connection: conn,
            startTime: startTime,
            isTruncated: outcome.isTruncated,
            statusMessage: outcome.statusMessage,
            batchSize: Self.keySummaryBatchSize
        )
    }
}
