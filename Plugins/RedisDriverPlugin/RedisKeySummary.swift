//
//  RedisKeySummary.swift
//  RedisDriverPlugin
//

import Foundation
import TableProPluginKit

enum RedisKeyKind: String, CaseIterable {
    case string
    case hash
    case list
    case set
    case zset
    case stream

    init?(typeName: String) {
        self.init(rawValue: typeName.lowercased())
    }
}

enum RedisKeySummary {
    static let collectionPreviewLimit = 100
    static let streamPreviewLimit = 5

    static func lengthCommand(for kind: RedisKeyKind, key: String) -> [String] {
        switch kind {
        case .string:
            return ["STRLEN", key]
        case .hash:
            return ["HLEN", key]
        case .list:
            return ["LLEN", key]
        case .set:
            return ["SCARD", key]
        case .zset:
            return ["ZCARD", key]
        case .stream:
            return ["XLEN", key]
        }
    }

    static func previewCommand(for kind: RedisKeyKind, key: String) -> [String] {
        switch kind {
        case .string:
            return ["GET", key]
        case .hash:
            return ["HSCAN", key, "0", "COUNT", String(collectionPreviewLimit)]
        case .list:
            return ["LRANGE", key, "0", String(collectionPreviewLimit - 1)]
        case .set:
            return ["SSCAN", key, "0", "COUNT", String(collectionPreviewLimit)]
        case .zset:
            return ["ZRANGE", key, "0", String(collectionPreviewLimit - 1), "WITHSCORES"]
        case .stream:
            return ["XREVRANGE", key, "+", "-", "COUNT", String(streamPreviewLimit)]
        }
    }

    static func jsonObject(flatPairs: [String]) -> String? {
        var object: [String: String] = [:]
        object.reserveCapacity(flatPairs.count / 2)
        for pair in pairs(from: flatPairs) {
            object[pair.first] = pair.second
        }
        return encode(object)
    }

    static func jsonArray(elements: [String]) -> String? {
        encode(elements)
    }

    static func jsonScorePairs(flatPairs: [String]) -> String? {
        encode(pairs(from: flatPairs).map { [$0.first, $0.second] })
    }

    static func jsonStreamEntries(_ entries: [(id: String, flatFields: [String])]) -> String? {
        let encoded = entries.map { entry -> [Any] in
            var fields: [String: String] = [:]
            fields.reserveCapacity(entry.flatFields.count / 2)
            for pair in pairs(from: entry.flatFields) {
                fields[pair.first] = pair.second
            }
            return [entry.id, fields]
        }
        return encode(encoded)
    }

    static func pairs(from flat: [String]) -> [(first: String, second: String)] {
        var result: [(first: String, second: String)] = []
        result.reserveCapacity(flat.count / 2)
        var index = 0
        while index + 1 < flat.count {
            result.append((first: flat[index], second: flat[index + 1]))
            index += 2
        }
        return result
    }

    private static func encode(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// What the server said about one key. Either half is nil when the server would not say, which
/// an ACL user whose key patterns do not cover the key gets for both, while `SCAN` still lists it.
struct RedisKeyDescription: Equatable, Sendable {
    let typeName: String?
    let ttlSeconds: Int?

    var kind: RedisKeyKind? {
        typeName.flatMap(RedisKeyKind.init(typeName:))
    }

    var typeCell: PluginCellValue {
        .fromOptional(typeName?.uppercased())
    }

    var ttlCell: PluginCellValue {
        .fromOptional(ttlSeconds.map(String.init))
    }
}

struct RedisKeyContents {
    let kind: RedisKeyKind
    let length: Int?
    let preview: RedisReply?

    var lengthCell: PluginCellValue {
        .fromOptional(length.map(String.init))
    }
}

extension RedisCommandChannel {
    func keyTypeNames(_ keys: [String]) async throws -> [String?] {
        try await runMetadataReads(keys.map { ["TYPE", $0] }).map { $0?.stringValue }
    }

    func describeKeys(_ keys: [String]) async throws -> [RedisKeyDescription] {
        let answers = try await runMetadataReads(keys.flatMap { [["TYPE", $0], ["TTL", $0]] })
        return stride(from: 0, to: answers.count - 1, by: 2).map { index in
            RedisKeyDescription(typeName: answers[index]?.stringValue, ttlSeconds: answers[index + 1]?.intValue)
        }
    }

    /// A key whose type is unknown gets no probe at all, because the length and preview commands
    /// are chosen by type.
    func readContents(
        of keys: [String],
        describedAs descriptions: [RedisKeyDescription]
    ) async throws -> [RedisKeyContents?] {
        let kinds = zip(keys, descriptions).map { (key: $0, kind: $1.kind) }
        var commands: [[String]] = []
        commands.reserveCapacity(kinds.count * 2)
        for entry in kinds {
            guard let kind = entry.kind else { continue }
            commands.append(RedisKeySummary.lengthCommand(for: kind, key: entry.key))
            commands.append(RedisKeySummary.previewCommand(for: kind, key: entry.key))
        }
        let answers = try await runMetadataReads(commands)

        var contents: [RedisKeyContents?] = []
        contents.reserveCapacity(kinds.count)
        var next = answers.startIndex
        for entry in kinds {
            guard let kind = entry.kind, next + 1 < answers.endIndex else {
                contents.append(nil)
                continue
            }
            contents.append(RedisKeyContents(kind: kind, length: answers[next]?.intValue, preview: answers[next + 1]))
            next += 2
        }
        return contents
    }
}
