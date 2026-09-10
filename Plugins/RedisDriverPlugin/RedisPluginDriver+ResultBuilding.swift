//
//  RedisPluginDriver+ResultBuilding.swift
//  RedisDriverPlugin
//

import Foundation
import TableProPluginKit

private struct RedisKeyProbe {
    let kind: RedisKeyKind
    let lengthIndex: Int
    let previewIndex: Int
}

extension RedisPluginDriver {
    static let keyBrowseColumns = ["Key", "Type", "TTL", "Length", "Value"]
    static let keyBrowseColumnTypeNames = ["String", "RedisType", "RedisInt", "Int64", "RedisRaw"]
    static let keyTreeColumns = ["Key", "Type"]
    static let keyTreeColumnTypeNames = ["String", "RedisType"]

    func buildKeyTreeResult(
        keys: [String],
        connection conn: any RedisCommandChannel,
        startTime: Date,
        isTruncated: Bool
    ) async throws -> PluginQueryResult {
        var rows: [PluginRow] = []
        if !keys.isEmpty {
            let typeReplies = try await conn.executePipeline(keys.map { ["TYPE", $0] })
            rows.reserveCapacity(keys.count)
            for (i, key) in keys.enumerated() {
                rows.append([.text(key), .text((typeReplies[i].stringValue ?? "unknown").uppercased())])
            }
        }

        return PluginQueryResult(
            columns: Self.keyTreeColumns,
            columnTypeNames: Self.keyTreeColumnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated
        )
    }

    func buildKeyBrowseResult(
        keys: [String],
        connection conn: any RedisCommandChannel,
        startTime: Date,
        isTruncated: Bool = false
    ) async throws -> PluginQueryResult {
        guard !keys.isEmpty else {
            return buildEmptyKeyResult(startTime: startTime)
        }

        let rows = try await buildKeySummaryRows(keys: keys, connection: conn)
        return PluginQueryResult(
            columns: Self.keyBrowseColumns,
            columnTypeNames: Self.keyBrowseColumnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated
        )
    }

    func buildKeySummaryRows(
        keys: [String],
        connection conn: any RedisCommandChannel
    ) async throws -> [PluginRow] {
        guard !keys.isEmpty else { return [] }

        var typeAndTtlCommands: [[String]] = []
        typeAndTtlCommands.reserveCapacity(keys.count * 2)
        for key in keys {
            typeAndTtlCommands.append(["TYPE", key])
            typeAndTtlCommands.append(["TTL", key])
        }
        let typeAndTtlReplies = try await conn.executePipeline(typeAndTtlCommands)

        var typeNames: [String] = []
        typeNames.reserveCapacity(keys.count)
        var ttlValues: [Int] = []
        ttlValues.reserveCapacity(keys.count)
        for i in 0 ..< keys.count {
            typeNames.append((typeAndTtlReplies[i * 2].stringValue ?? "unknown").uppercased())
            ttlValues.append(typeAndTtlReplies[i * 2 + 1].intValue ?? -1)
        }

        var probeCommands: [[String]] = []
        probeCommands.reserveCapacity(keys.count * 2)
        var probes: [RedisKeyProbe?] = []
        probes.reserveCapacity(keys.count)

        for (i, key) in keys.enumerated() {
            guard let kind = RedisKeyKind(typeName: typeNames[i]) else {
                probes.append(nil)
                continue
            }
            let lengthIndex = probeCommands.count
            probeCommands.append(RedisKeySummary.lengthCommand(for: kind, key: key))
            let previewIndex = probeCommands.count
            probeCommands.append(RedisKeySummary.previewCommand(for: kind, key: key))
            probes.append(RedisKeyProbe(kind: kind, lengthIndex: lengthIndex, previewIndex: previewIndex))
        }

        var probeReplies: [RedisReply] = []
        if !probeCommands.isEmpty {
            probeReplies = try await conn.executePipeline(probeCommands)
        }

        var rows: [PluginRow] = []
        rows.reserveCapacity(keys.count)
        for (i, key) in keys.enumerated() {
            var length: String?
            var value = PluginCellValue.null
            if let probe = probes[i], probe.previewIndex < probeReplies.count {
                length = probeReplies[probe.lengthIndex].intValue.map(String.init)
                value = previewCell(probeReplies[probe.previewIndex], kind: probe.kind)
            }
            rows.append([
                .text(key),
                .text(typeNames[i]),
                .text(String(ttlValues[i])),
                PluginCellValue.fromOptional(length),
                value
            ])
        }
        return rows
    }

    func previewCell(_ reply: RedisReply, kind: RedisKeyKind) -> PluginCellValue {
        switch kind {
        case .string:
            return stringCell(from: reply)
        case .hash:
            return .fromOptional(RedisKeySummary.jsonObject(flatPairs: scanElements(from: reply).map(redisReplyToString)))
        case .list:
            return .fromOptional(RedisKeySummary.jsonArray(elements: (reply.arrayValue ?? []).map(redisReplyToString)))
        case .set:
            return .fromOptional(RedisKeySummary.jsonArray(elements: scanElements(from: reply).map(redisReplyToString)))
        case .zset:
            return .fromOptional(RedisKeySummary.jsonScorePairs(flatPairs: (reply.arrayValue ?? []).map(redisReplyToString)))
        case .stream:
            return .fromOptional(RedisKeySummary.jsonStreamEntries(streamEntries(from: reply)))
        }
    }

    func stringCell(from reply: RedisReply) -> PluginCellValue {
        switch reply {
        case .null, .error:
            return .null
        case .data(let bytes):
            return .bytes(bytes)
        default:
            return .text(redisReplyToString(reply))
        }
    }

    func scanElements(from reply: RedisReply) -> [RedisReply] {
        if case .array(let parts) = reply, parts.count == 2, let items = parts[1].arrayValue {
            return items
        }
        return reply.arrayValue ?? []
    }

    func streamEntries(from reply: RedisReply) -> [(id: String, flatFields: [String])] {
        guard let entries = reply.arrayValue else { return [] }
        return entries.compactMap { entry in
            guard let parts = entry.arrayValue, parts.count >= 2,
                  let fields = parts[1].arrayValue else {
                return nil
            }
            return (id: redisReplyToString(parts[0]), flatFields: fields.map(redisReplyToString))
        }
    }

    func buildEmptyKeyResult(startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: Self.keyBrowseColumns,
            columnTypeNames: Self.keyBrowseColumnTypeNames,
            rows: [],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildStatusResult(_ message: String, startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["status"],
            columnTypeNames: ["String"],
            rows: [[message].asCells],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildGenericResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        switch result {
        case .string(let s), .status(let s):
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [[s].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .integer(let i):
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["Int64"],
                rows: [[String(i)].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .data(let d):
            let str = String(data: d, encoding: .utf8) ?? d.base64EncodedString()
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [[str].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .array(let items):
            let rows = items.map { ([redisReplyToString($0)] as [String?]).asCells }
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .error(let e):
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [[e].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .null:
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [["(nil)"].asCells],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    func redisReplyToString(_ reply: RedisReply) -> String {
        switch reply {
        case .string(let s), .status(let s), .error(let s): return s
        case .integer(let i): return String(i)
        case .data(let d): return String(data: d, encoding: .utf8) ?? d.base64EncodedString()
        case .array(let items): return "[\(items.map { redisReplyToString($0) }.joined(separator: ", "))]"
        case .null: return "(nil)"
        }
    }

    func buildHashResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let items = result.arrayValue, !items.isEmpty else {
            return PluginQueryResult(
                columns: ["Field", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        var rows: [[PluginCellValue]] = []
        var i = 0
        while i + 1 < items.count {
            rows.append([redisReplyToString(items[i]), redisReplyToString(items[i + 1])].asCells)
            i += 2
        }

        return PluginQueryResult(
            columns: ["Field", "Value"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildListResult(_ result: RedisReply, startOffset: Int = 0, startTime: Date) -> PluginQueryResult {
        guard let items = result.arrayValue else {
            return PluginQueryResult(
                columns: ["Index", "Value"],
                columnTypeNames: ["Int64", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let rows = items.enumerated().map { index, item -> [PluginCellValue] in
            ([String(startOffset + index), redisReplyToString(item)] as [String?]).asCells
        }

        return PluginQueryResult(
            columns: ["Index", "Value"],
            columnTypeNames: ["Int64", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildSetResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let items = result.arrayValue else {
            return PluginQueryResult(
                columns: ["Member"],
                columnTypeNames: ["String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let rows = items.map { ([redisReplyToString($0)] as [String?]).asCells }

        return PluginQueryResult(
            columns: ["Member"],
            columnTypeNames: ["String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildSortedSetResult(_ result: RedisReply, withScores: Bool, startTime: Date) -> PluginQueryResult {
        guard let items = result.arrayValue else {
            return PluginQueryResult(
                columns: withScores ? ["Member", "Score"] : ["Member"],
                columnTypeNames: withScores ? ["String", "Double"] : ["String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        if withScores {
            var rows: [[PluginCellValue]] = []
            var i = 0
            while i + 1 < items.count {
                rows.append([redisReplyToString(items[i]), redisReplyToString(items[i + 1])].asCells)
                i += 2
            }
            return PluginQueryResult(
                columns: ["Member", "Score"],
                columnTypeNames: ["String", "Double"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        } else {
            let rows = items.map { ([redisReplyToString($0)] as [String?]).asCells }
            return PluginQueryResult(
                columns: ["Member"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    func buildStreamResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let entries = result.arrayValue else {
            return PluginQueryResult(
                columns: ["ID", "Fields"],
                columnTypeNames: ["String", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        var rows: [[PluginCellValue]] = []
        for entry in entries {
            guard let entryParts = entry.arrayValue, entryParts.count >= 2,
                  let fields = entryParts[1].arrayValue else {
                continue
            }
            let entryId = redisReplyToString(entryParts[0])

            var fieldPairs: [String] = []
            var i = 0
            while i + 1 < fields.count {
                fieldPairs.append("\(redisReplyToString(fields[i]))=\(redisReplyToString(fields[i + 1]))")
                i += 2
            }
            rows.append([entryId, fieldPairs.joined(separator: ", ")].asCells)
        }

        return PluginQueryResult(
            columns: ["ID", "Fields"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildConfigResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let items = result.arrayValue, !items.isEmpty else {
            return PluginQueryResult(
                columns: ["Parameter", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        var rows: [[PluginCellValue]] = []
        var i = 0
        while i + 1 < items.count {
            rows.append([redisReplyToString(items[i]), redisReplyToString(items[i + 1])].asCells)
            i += 2
        }

        return PluginQueryResult(
            columns: ["Parameter", "Value"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }
}
