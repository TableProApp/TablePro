import Foundation

nonisolated internal struct RedisScanPage: Equatable, Sendable {
    static let startCursor = "0"

    let cursor: String
    let keys: [String]

    init(cursor: String, keys: [String]) {
        self.cursor = cursor
        self.keys = keys
    }

    init(reply: RedisReplyValue) throws {
        try reply.throwIfError().throwIfQueued("SCAN")
        guard case .array(let parts) = reply, parts.count == 2 else {
            self.init(cursor: Self.startCursor, keys: [])
            return
        }
        self.init(cursor: Self.cursor(from: parts[0]), keys: Self.keys(from: parts[1]))
    }

    private static func cursor(from reply: RedisReplyValue) -> String {
        switch reply {
        case .string(let value), .status(let value):
            return value
        case .integer(let value):
            return String(value)
        default:
            return startCursor
        }
    }

    private static func keys(from reply: RedisReplyValue) -> [String] {
        guard case .array(let items) = reply else { return [] }
        return items.compactMap { item in
            switch item {
            case .string(let key), .status(let key):
                return key
            default:
                return nil
            }
        }
    }
}

nonisolated internal enum RedisKeyspaceReads {
    typealias Send = ([String]) async throws -> RedisReplyValue

    static let scanPageSize = 1_000
    static let keyLimit = 100_000
    static let unknownTypeName = "unknown"

    static func scanArguments(cursor: String) -> [String] {
        ["SCAN", cursor, "MATCH", "*", "COUNT", String(scanPageSize)]
    }

    /// SCAN may return a key more than once, for example when the keyspace shrinks during the walk,
    /// so each key is kept at its first sighting. The limit counts every key the server sent,
    /// repeats included, because it bounds the round trips rather than the size of the list.
    static func keys(sending send: Send) async throws -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        var received = 0
        var cursor = RedisScanPage.startCursor
        repeat {
            let reply = try await send(scanArguments(cursor: cursor))
            let page = try RedisScanPage(reply: reply)
            cursor = page.cursor
            received += page.keys.count
            for key in page.keys where seen.insert(key).inserted {
                keys.append(key)
            }
        } while cursor != RedisScanPage.startCursor && received < keyLimit
        return keys
    }

    static func typeName(ofKey key: String, sending send: Send) async throws -> String {
        let reply = try await send(["TYPE", key]).throwIfError().throwIfQueued("TYPE")
        switch reply {
        case .status(let name), .string(let name):
            return name
        default:
            return unknownTypeName
        }
    }
}
