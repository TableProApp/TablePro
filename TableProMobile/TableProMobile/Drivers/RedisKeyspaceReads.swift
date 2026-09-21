import Foundation

nonisolated internal struct RedisScanPage: Equatable, Sendable {
    static let startCursor = "0"

    let cursor: String
    let elements: [String]

    init(cursor: String, elements: [String]) {
        self.cursor = cursor
        self.elements = elements
    }

    init(reply: RedisReplyValue, command: String) throws {
        try reply.throwIfError().throwIfQueued(command)
        guard case .array(let parts) = reply, parts.count == 2 else {
            self.init(cursor: Self.startCursor, elements: [])
            return
        }
        self.init(cursor: Self.cursor(from: parts[0]), elements: parts[1].stringElements)
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
            let page = try RedisScanPage(reply: reply, command: "SCAN")
            cursor = page.cursor
            received += page.elements.count
            for key in page.elements where seen.insert(key).inserted {
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
