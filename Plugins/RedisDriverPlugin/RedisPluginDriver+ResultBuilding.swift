//
//  RedisPluginDriver+ResultBuilding.swift
//  RedisDriverPlugin
//

import Foundation
import TableProPluginKit

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

        let descriptions = try await conn.describeKeys(keys)
        let contents = try await conn.readContents(of: keys, describedAs: descriptions)
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
        content.preview.map { previewCell($0, kind: content.kind) }
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
}
