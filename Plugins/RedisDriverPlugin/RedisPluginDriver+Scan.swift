//
//  RedisPluginDriver+Scan.swift
//  RedisDriverPlugin
//

import Foundation
import OSLog
import TableProPluginKit

extension RedisPluginDriver {
    func scanAllKeys(
        connection conn: any RedisCommandChannel,
        pattern: String?,
        typeFilter: String? = nil,
        maxKeys: Int
    ) async throws -> [String] {
        var allKeys: [String] = []
        var cursor = RedisClusterCursor.start

        repeat {
            try Task.checkCancellation()
            let page = try await conn.scanKeyspace(
                cursor: cursor, pattern: pattern, type: typeFilter, count: 1_000
            )
            cursor = page.cursor
            allKeys.append(contentsOf: page.keys)
            if allKeys.count >= maxKeys {
                return Array(allKeys.prefix(maxKeys)).sorted()
            }
        } while cursor != RedisClusterCursor.start

        return allKeys.sorted()
    }

    func executeKeyBrowse(
        pattern: String?,
        typeScope: String?,
        limit: Int,
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
        let scanWasCapped = rawKeys.count >= scanCap

        let pageStart = min(max(0, offset), matchedKeys.count)
        let pageEnd = limit <= 0 ? matchedKeys.count : min(pageStart + limit, matchedKeys.count)
        let pageKeys = Array(matchedKeys[pageStart..<pageEnd])

        return try await buildKeyBrowseResult(
            keys: pageKeys, connection: conn, startTime: startTime, isTruncated: scanWasCapped
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
        let capped = Array(page.keys.prefix(PluginRowLimits.emergencyMax))
        let truncated = page.isIncomplete || page.keys.count > PluginRowLimits.emergencyMax
        return try await buildKeyBrowseResult(
            keys: capped, connection: conn, startTime: startTime, isTruncated: truncated
        )
    }
}
