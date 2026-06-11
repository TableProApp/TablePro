//
//  RedisPluginDriver+Scan.swift
//  RedisDriverPlugin
//

import Foundation
import OSLog
import TableProPluginKit

extension RedisPluginDriver {
    func scanAllKeys(
        connection conn: RedisPluginConnection,
        pattern: String?,
        typeFilter: String? = nil,
        maxKeys: Int
    ) async throws -> [String] {
        var allKeys: [String] = []
        var cursor = "0"

        repeat {
            var args = ["SCAN", cursor]
            if let p = pattern {
                args += ["MATCH", p]
            }
            args += ["COUNT", "1000"]
            if let type = typeFilter {
                args += ["TYPE", type]
            }

            let result = try await conn.executeCommand(args)

            guard case .array(let scanResult) = result,
                  scanResult.count == 2 else {
                break
            }

            let nextCursor: String
            switch scanResult[0] {
            case .string(let s): nextCursor = s
            case .status(let s): nextCursor = s
            case .data(let d): nextCursor = String(data: d, encoding: .utf8) ?? "0"
            default: nextCursor = "0"
            }
            cursor = nextCursor

            if case .array(let keyReplies) = scanResult[1] {
                for reply in keyReplies {
                    switch reply {
                    case .string(let k): allKeys.append(k)
                    case .data(let d):
                        if let k = String(data: d, encoding: .utf8) { allKeys.append(k) }
                    default: break
                    }
                }
            }

            if allKeys.count >= maxKeys {
                allKeys = Array(allKeys.prefix(maxKeys))
                break
            }
        } while cursor != "0"

        return allKeys.sorted()
    }

    func executeKeyBrowse(
        pattern: String?,
        typeScope: String?,
        limit: Int,
        offset: Int,
        connection conn: RedisPluginConnection,
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

    func handleScanResult(
        _ result: RedisReply,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard case .array(let scanResult) = result,
              scanResult.count == 2,
              case .array(let keyReplies) = scanResult[1] else {
            return buildEmptyKeyResult(startTime: startTime)
        }

        let keys = keyReplies.compactMap { reply -> String? in
            if case .string(let k) = reply { return k }
            if case .data(let d) = reply { return String(data: d, encoding: .utf8) }
            return nil
        }

        let capped = Array(keys.prefix(PluginRowLimits.emergencyMax))
        let keysTruncated = keys.count > PluginRowLimits.emergencyMax
        return try await buildKeyBrowseResult(
            keys: capped, connection: conn, startTime: startTime, isTruncated: keysTruncated
        )
    }
}
