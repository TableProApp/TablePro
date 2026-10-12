import Foundation
import TableProModels

nonisolated internal enum RedisKeyBrowse {
    static let missingTypeName = "none"
    static let scanCount = 1_000

    static func page(
        ofKey key: String,
        limit: Int,
        offset: Int,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> KeyContentsPage {
        let start = Date()
        let typeName = try await RedisKeyspaceReads.typeName(ofKey: key, sending: send)
        guard typeName != missingTypeName else { throw RedisError.keyNotFound(key) }
        guard let kind = RedisKeyKind(typeName: typeName) else { throw RedisError.keyTypeNotBrowsable(typeName) }

        let window = PageWindow(offset: max(offset, 0), limit: max(limit, 0))
        let totalCount = try await count(of: kind, key: key, sending: send)
        let rows = try await rows(of: kind, key: key, window: window, sending: send)
        let result = QueryResult(
            columns: columns(for: kind),
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(start)
        )
        return KeyContentsPage(result: result, totalCount: totalCount)
    }

    static func columns(for kind: RedisKeyKind) -> [ColumnInfo] {
        let fields: [(name: String, typeName: String)]
        switch kind {
        case .string:
            fields = [("value", "string")]
        case .list:
            fields = [("index", "integer"), ("element", "string")]
        case .zset:
            fields = [("member", "string"), ("score", "double")]
        case .hash:
            fields = [("field", "string"), ("value", "string")]
        case .set:
            fields = [("member", "string")]
        case .stream:
            fields = [("id", "string"), ("fields", "json")]
        }
        return fields.enumerated().map { position, field in
            ColumnInfo(name: field.name, typeName: field.typeName, ordinalPosition: position)
        }
    }

    private struct PageWindow {
        let offset: Int
        let limit: Int

        var end: Int { offset + limit }
        var lastIndex: Int { end - 1 }
    }

    private static func count(
        of kind: RedisKeyKind,
        key: String,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> Int? {
        guard kind != .string else { return 1 }
        let command = RedisKeySummary.lengthCommand(for: kind, key: key)
        let reply = try await checked(command, sending: send)
        guard case .integer(let length) = reply else { return nil }
        return Int(length)
    }

    private static func rows(
        of kind: RedisKeyKind,
        key: String,
        window: PageWindow,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> [[String?]] {
        guard window.limit > 0 else { return [] }
        switch kind {
        case .string:
            return try await stringRows(key: key, window: window, sending: send)
        case .list:
            return try await listRows(key: key, window: window, sending: send)
        case .zset:
            return try await sortedSetRows(key: key, window: window, sending: send)
        case .hash:
            let fields = try await scanned("HSCAN", key: key, collecting: window.end, sending: send) { elements in
                RedisKeySummary.pairs(from: elements).map { [$0.first, $0.second] }
            }
            return slice(fields, to: window)
        case .set:
            let members = try await scanned("SSCAN", key: key, collecting: window.end, sending: send) { elements in
                elements.map { [$0] }
            }
            return slice(members, to: window)
        case .stream:
            return try await streamRows(key: key, window: window, sending: send)
        }
    }

    private static func stringRows(
        key: String,
        window: PageWindow,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> [[String?]] {
        guard window.offset == 0 else { return [] }
        let reply = try await checked(["GET", key], sending: send)
        guard reply != .null else { throw RedisError.keyNotFound(key) }
        return [[reply.stringRepresentation]]
    }

    private static func listRows(
        key: String,
        window: PageWindow,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> [[String?]] {
        let command = ["LRANGE", key, String(window.offset), String(window.lastIndex)]
        let elements = try await checked(command, sending: send).stringElements
        return elements.enumerated().map { position, element in
            [String(window.offset + position), element]
        }
    }

    private static func sortedSetRows(
        key: String,
        window: PageWindow,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> [[String?]] {
        let command = ["ZRANGE", key, String(window.offset), String(window.lastIndex), "WITHSCORES"]
        let elements = try await checked(command, sending: send).stringElements
        return RedisKeySummary.pairs(from: elements).map { [$0.first, $0.second] }
    }

    private static func streamRows(
        key: String,
        window: PageWindow,
        sending send: RedisKeyspaceReads.Send
    ) async throws -> [[String?]] {
        let reply = try await checked(["XRANGE", key, "-", "+", "COUNT", String(window.end)], sending: send)
        guard case .array(let entries) = reply else { return [] }
        return entries.dropFirst(window.offset).compactMap { entry -> [String?]? in
            guard case .array(let parts) = entry, let id = parts.first?.stringRepresentation else { return nil }
            let fields = parts.count > 1 ? parts[1].stringElements : []
            return [id, RedisKeySummary.jsonObject(flatPairs: fields)]
        }
    }

    /// HSCAN and SSCAN may return an element more than once, so each is kept at its first sighting.
    /// The walk ends once the page is covered or the cursor comes back to 0. The last bound only
    /// stops a server that keeps repeating itself without ever ending its cursor.
    private static func scanned(
        _ command: String,
        key: String,
        collecting needed: Int,
        sending send: RedisKeyspaceReads.Send,
        entries: ([String]) -> [[String]]
    ) async throws -> [[String]] {
        var collected: [[String]] = []
        var seen = Set<String>()
        var received = 0
        var cursor = RedisScanPage.startCursor
        repeat {
            let reply = try await send([command, key, cursor, "COUNT", String(scanCount)])
            let page = try RedisScanPage(reply: reply, command: command)
            cursor = page.cursor
            let pageEntries = entries(page.elements)
            received += pageEntries.count
            for entry in pageEntries {
                guard let identity = entry.first, seen.insert(identity).inserted else { continue }
                collected.append(entry)
            }
        } while cursor != RedisScanPage.startCursor
            && collected.count < needed
            && received < needed + RedisKeyspaceReads.keyLimit
        return collected
    }

    private static func slice(_ entries: [[String]], to window: PageWindow) -> [[String?]] {
        guard window.offset < entries.count else { return [] }
        return entries[window.offset ..< min(window.end, entries.count)].map { $0.map(Optional.some) }
    }

    private static func checked(
        _ command: [String],
        sending send: RedisKeyspaceReads.Send
    ) async throws -> RedisReplyValue {
        try await send(command).throwIfError().throwIfQueued(command[0])
    }
}
