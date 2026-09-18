//
//  RedisKeySummary.swift
//  RedisDriverPlugin
//

import Foundation

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
