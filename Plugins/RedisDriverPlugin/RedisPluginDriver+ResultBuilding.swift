//
//  RedisPluginDriver+ResultBuilding.swift
//  RedisDriverPlugin
//

import Foundation
import OSLog
import TableProPluginKit

extension RedisPluginDriver {
    static let previewLimit = 100
    static let previewMaxChars = 1_000

    func buildKeyBrowseResult(
        keys: [String],
        connection conn: RedisPluginConnection,
        startTime: Date,
        isTruncated: Bool = false
    ) async throws -> PluginQueryResult {
        guard !keys.isEmpty else {
            return buildEmptyKeyResult(startTime: startTime)
        }

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
            let typeName = (typeAndTtlReplies[i * 2].stringValue ?? "unknown").uppercased()
            let ttl = typeAndTtlReplies[i * 2 + 1].intValue ?? -1
            typeNames.append(typeName)
            ttlValues.append(ttl)
        }

        var previewCommands: [[String]] = []
        previewCommands.reserveCapacity(keys.count)
        var previewCommandIndices: [Int] = []
        previewCommandIndices.reserveCapacity(keys.count)

        for (i, key) in keys.enumerated() {
            let command: [String]? = previewCommandForType(typeNames[i], key: key)
            if let command {
                previewCommandIndices.append(previewCommands.count)
                previewCommands.append(command)
            } else {
                previewCommandIndices.append(-1)
            }
        }

        var previewReplies: [RedisReply] = []
        if !previewCommands.isEmpty {
            previewReplies = try await conn.executePipeline(previewCommands)
        }

        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(keys.count)
        for (i, key) in keys.enumerated() {
            let ttlStr = String(ttlValues[i])
            let pipelineIndex = previewCommandIndices[i]
            let preview: String?
            if pipelineIndex >= 0, pipelineIndex < previewReplies.count {
                preview = formatPreviewReply(
                    previewReplies[pipelineIndex], type: typeNames[i]
                )
            } else {
                preview = nil
            }
            rows.append([key, typeNames[i], ttlStr, preview].asCells)
        }

        return PluginQueryResult(
            columns: ["Key", "Type", "TTL", "Value"],
            columnTypeNames: ["String", "RedisType", "RedisInt", "RedisRaw"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated
        )
    }

    func previewCommandForType(_ type: String, key: String) -> [String]? {
        switch type.lowercased() {
        case "string":
            return ["GET", key]
        case "hash":
            return ["HSCAN", key, "0", "COUNT", String(Self.previewLimit)]
        case "list":
            return ["LRANGE", key, "0", String(Self.previewLimit - 1)]
        case "set":
            return ["SSCAN", key, "0", "COUNT", String(Self.previewLimit)]
        case "zset":
            return ["ZRANGE", key, "0", String(Self.previewLimit - 1), "WITHSCORES"]
        case "stream":
            return ["XREVRANGE", key, "+", "-", "COUNT", "5"]
        default:
            return nil
        }
    }

    func formatPreviewReply(_ reply: RedisReply, type: String) -> String? {
        switch type.lowercased() {
        case "string":
            return truncatePreview(redisReplyToString(reply))

        case "hash":
            let array: [RedisReply]
            if case .array(let scanResult) = reply,
               scanResult.count == 2,
               let items = scanResult[1].arrayValue {
                array = items
            } else if let items = reply.arrayValue, !items.isEmpty {
                array = items
            } else {
                return "{}"
            }
            guard !array.isEmpty else { return "{}" }
            var pairs: [String] = []
            var idx = 0
            while idx + 1 < array.count {
                let field = redisReplyToString(array[idx])
                let value = redisReplyToString(array[idx + 1])
                pairs.append(
                    "\"\(escapeJsonString(field))\":\"\(escapeJsonString(value))\""
                )
                idx += 2
            }
            return truncatePreview("{\(pairs.joined(separator: ","))}")

        case "list":
            guard let items = reply.arrayValue else { return "[]" }
            let quoted = items.map { "\"\(escapeJsonString(redisReplyToString($0)))\"" }
            return truncatePreview("[\(quoted.joined(separator: ", "))]")

        case "set":
            let members: [RedisReply]
            if case .array(let scanResult) = reply,
               scanResult.count == 2,
               let items = scanResult[1].arrayValue {
                members = items
            } else if let items = reply.arrayValue {
                members = items
            } else {
                return "[]"
            }
            let quoted = members.map { "\"\(escapeJsonString(redisReplyToString($0)))\"" }
            return truncatePreview("[\(quoted.joined(separator: ", "))]")

        case "zset":
            // Parse WITHSCORES result: alternating member, score pairs
            guard let items = reply.arrayValue, !items.isEmpty else { return "[]" }
            var pairs: [String] = []
            var i = 0
            while i + 1 < items.count {
                pairs.append("\(redisReplyToString(items[i])):\(redisReplyToString(items[i + 1]))")
                i += 2
            }
            return truncatePreview(pairs.joined(separator: ", "))

        case "stream":
            // Parse XREVRANGE result: array of [id, [field, value, ...]] entries
            guard let entries = reply.arrayValue, !entries.isEmpty else {
                return "(0 entries)"
            }
            var entryStrings: [String] = []
            for entry in entries {
                guard let parts = entry.arrayValue, parts.count >= 2,
                      let fields = parts[1].arrayValue else {
                    continue
                }
                let entryId = redisReplyToString(parts[0])
                var fieldPairs: [String] = []
                var j = 0
                while j + 1 < fields.count {
                    fieldPairs.append("\(redisReplyToString(fields[j]))=\(redisReplyToString(fields[j + 1]))")
                    j += 2
                }
                entryStrings.append("\(entryId): \(fieldPairs.joined(separator: ", "))")
            }
            return truncatePreview(entryStrings.joined(separator: "; "))

        default:
            return nil
        }
    }

    func truncatePreview(_ value: String?) -> String? {
        guard let value else { return nil }
        let nsValue = value as NSString
        if nsValue.length > Self.previewMaxChars {
            return nsValue.substring(to: Self.previewMaxChars) + "..."
        }
        return value
    }

    func escapeJsonString(_ str: String) -> String {
        var result = ""
        for scalar in str.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result += String(scalar)
                }
            }
        }
        return result
    }

    func buildEmptyKeyResult(startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["Key", "Type", "TTL", "Value"],
            columnTypeNames: ["String", "RedisType", "RedisInt", "RedisRaw"],
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
