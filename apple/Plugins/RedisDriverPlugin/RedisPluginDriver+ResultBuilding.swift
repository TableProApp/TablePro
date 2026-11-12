//
//  RedisPluginDriver+ResultBuilding.swift
//  RedisDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProRedisCore

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
        let typeNames = try await conn.keyTypeNames(keys)
        let rows: [PluginRow] = zip(keys, typeNames).map { key, typeName in
            [.text(key), .fromOptional(typeName?.uppercased())]
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

    static let keySummaryBatchSize = 200

    // Nil sends every key in one pipeline: fine for a grid page the user sized, not for KEYS or SCAN.
    func buildKeyBrowseResult(
        keys: [String],
        connection conn: any RedisCommandChannel,
        startTime: Date,
        isTruncated: Bool = false,
        statusMessage: String? = nil,
        batchSize: Int? = nil
    ) async throws -> PluginQueryResult {
        guard !keys.isEmpty else {
            return buildEmptyKeyResult(startTime: startTime, statusMessage: statusMessage)
        }

        let rows = try await buildKeySummaryRows(
            keys: keys, connection: conn, stringByteLimit: RedisStringPreview.byteLimit, batchSize: batchSize
        )
        return PluginQueryResult(
            columns: Self.keyBrowseColumns,
            columnTypeNames: Self.keyBrowseColumnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated,
            statusMessage: statusMessage
        )
    }

    // A nil byte limit reads every string whole, which only an export wants.
    func buildKeySummaryRows(
        keys: [String],
        connection conn: any RedisCommandChannel,
        stringByteLimit: Int?,
        batchSize: Int? = nil
    ) async throws -> [PluginRow] {
        guard let batchSize, batchSize > 0, keys.count > batchSize else {
            return try await summarizeKeys(keys, connection: conn, stringByteLimit: stringByteLimit)
        }
        var rows: [PluginRow] = []
        rows.reserveCapacity(keys.count)
        for start in stride(from: 0, to: keys.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(keys[start ..< min(start + batchSize, keys.count)])
            rows += try await summarizeKeys(batch, connection: conn, stringByteLimit: stringByteLimit)
        }
        return rows
    }

    private func summarizeKeys(
        _ keys: [String],
        connection conn: any RedisCommandChannel,
        stringByteLimit: Int?
    ) async throws -> [PluginRow] {
        guard !keys.isEmpty else { return [] }

        let descriptions = try await conn.describeKeys(keys)
        let contents = try await conn.readContents(of: keys, describedAs: descriptions, stringByteLimit: stringByteLimit)
        return zip(keys, zip(descriptions, contents)).map { key, summary in
            let (description, content) = summary
            return [
                .text(key),
                description.typeCell,
                description.ttlCell,
                content?.lengthCell ?? .null,
                content.flatMap(valueCell(for:)) ?? .null
            ]
        }
    }

    private func valueCell(for content: RedisKeyContents) -> PluginCellValue? {
        guard let preview = content.preview else { return nil }
        guard content.kind == .string, let byteLimit = content.stringByteLimit else {
            return previewCell(preview, kind: content.kind)
        }
        return shownStringCell(preview, length: content.length, byteLimit: byteLimit)
    }

    private func shownStringCell(_ reply: RedisReply, length: Int?, byteLimit: Int) -> PluginCellValue {
        let bytes: Data
        switch reply {
        case .string(let text): bytes = Data(text.utf8)
        case .data(let data): bytes = data
        default: return stringCell(from: reply)
        }
        switch RedisStringPreview.shown(bytes, length: length, byteLimit: byteLimit) {
        case .text(let text): return .text(text)
        case .bytes(let data): return .bytes(data)
        }
    }

    func previewCell(_ reply: RedisReply, kind: RedisKeyKind) -> PluginCellValue {
        switch kind {
        case .string:
            return stringCell(from: reply)
        case .hash:
            return .fromOptional(RedisKeySummary.jsonObject(flatPairs: scanElements(from: reply).map(\.displayText)))
        case .list:
            return .fromOptional(RedisKeySummary.jsonArray(elements: (reply.arrayValue ?? []).map(\.displayText)))
        case .set:
            return .fromOptional(RedisKeySummary.jsonArray(elements: scanElements(from: reply).map(\.displayText)))
        case .zset:
            return .fromOptional(RedisKeySummary.jsonScorePairs(flatPairs: (reply.arrayValue ?? []).map(\.displayText)))
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
            return .text(reply.displayText)
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
            return (id: parts[0].displayText, flatFields: fields.map(\.displayText))
        }
    }

    func buildEmptyKeyResult(startTime: Date, statusMessage: String? = nil) -> PluginQueryResult {
        PluginQueryResult(
            columns: Self.keyBrowseColumns,
            columnTypeNames: Self.keyBrowseColumnTypeNames,
            rows: [],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            statusMessage: statusMessage
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
}
