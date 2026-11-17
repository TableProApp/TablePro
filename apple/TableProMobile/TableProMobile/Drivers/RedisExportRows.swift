import Foundation
import TableProModels
import TableProPluginKit
import TableProRedisCore

// The rows the Mac's `KEYBROWSE` export streams for one database (`RedisPluginDriver.streamScanRows`): every key SCAN
// lists, with its type, TTL, length and value, the value whole for a string and the Mac's preview for a collection.
nonisolated enum RedisExportRows {
    static let columns = ["Key", "Type", "TTL", "Length", "Value"]
    static let columnTypeNames = ["String", "RedisType", "RedisInt", "Int64", "RedisRaw"]
    static let batchSize = 200

    typealias Send = @Sendable ([String]) async throws -> RedisReplyValue
    typealias ReadBytes = @Sendable ([String]) async throws -> Data?

    enum Request: Equatable {
        case keyBrowse(database: Int?)
        case command
    }

    // The export statement the catalog hands out (`RedisQueryBuilder.buildExportQuery`), or any other command.
    static func request(for query: String) -> Request {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first?.uppercased() == "KEYBROWSE" else { return .command }
        guard words.count >= 3, words[1].uppercased() == "DB" else { return .keyBrowse(database: nil) }
        return .keyBrowse(database: RedisDatabaseIndex.parse(words[2]))
    }

    // A reply the server refused, which an ACL user gets for a key outside its patterns, is an empty cell, as on the Mac.
    static func rows(keys: [String], send: Send, readBytes: ReadBytes) async throws -> [PluginRow] {
        var rows: [PluginRow] = []
        rows.reserveCapacity(keys.count)
        for key in keys {
            try Task.checkCancellation()
            rows.append(try await row(key: key, send: send, readBytes: readBytes))
        }
        return rows
    }

    static func row(key: String, send: Send, readBytes: ReadBytes) async throws -> PluginRow {
        let typeName = answered(try await send(["TYPE", key])).flatMap(text)
        let ttl = answered(try await send(["TTL", key])).flatMap(integer)
        var length: PluginCellValue = .null
        var value: PluginCellValue = .null
        if let typeName, let kind = RedisKeyKind(typeName: typeName) {
            length = .fromOptional(answered(try await send(RedisKeySummary.lengthCommand(for: kind, key: key)))
                .flatMap(integer).map(String.init))
            if kind == .string {
                value = try await readBytes(["GET", key]).map(stringCell) ?? .null
            } else if let preview = answered(try await send(RedisKeySummary.previewCommand(for: kind, key: key))) {
                value = previewCell(preview, kind: kind)
            }
        }
        return [
            .text(key),
            .fromOptional(typeName?.uppercased()),
            .fromOptional(ttl.map(String.init)),
            length,
            value,
        ]
    }

    static func stringCell(_ bytes: Data) -> PluginCellValue {
        RedisWireText.decode(bytes).map(PluginCellValue.text) ?? .bytes(bytes)
    }

    static func previewCell(_ reply: RedisReplyValue, kind: RedisKeyKind) -> PluginCellValue {
        switch kind {
        case .string:
            return .fromOptional(reply.stringRepresentation)
        case .hash:
            return .fromOptional(RedisKeySummary.jsonObject(flatPairs: scanElements(of: reply).map(displayText)))
        case .list:
            return .fromOptional(RedisKeySummary.jsonArray(elements: elements(of: reply).map(displayText)))
        case .set:
            return .fromOptional(RedisKeySummary.jsonArray(elements: scanElements(of: reply).map(displayText)))
        case .zset:
            return .fromOptional(RedisKeySummary.jsonScorePairs(flatPairs: elements(of: reply).map(displayText)))
        case .stream:
            return .fromOptional(RedisKeySummary.jsonStreamEntries(streamEntries(of: reply)))
        }
    }

    // The Mac's `RedisReply.displayText`.
    static func displayText(_ reply: RedisReplyValue) -> String {
        switch reply {
        case .string(let text), .status(let text): return text
        case .error(let message): return "(error) \(message)"
        case .integer(let value): return String(value)
        case .array(let items): return "[\(items.map(displayText).joined(separator: ", "))]"
        case .null: return "(nil)"
        }
    }

    private static func answered(_ reply: RedisReplyValue) -> RedisReplyValue? {
        switch reply {
        case .error, .null: return nil
        default: return reply.isQueued ? nil : reply
        }
    }

    private static func text(_ reply: RedisReplyValue) -> String? {
        switch reply {
        case .string(let value), .status(let value): return value
        default: return nil
        }
    }

    private static func integer(_ reply: RedisReplyValue) -> Int64? {
        guard case .integer(let value) = reply else { return nil }
        return value
    }

    private static func elements(of reply: RedisReplyValue) -> [RedisReplyValue] {
        guard case .array(let items) = reply else { return [] }
        return items
    }

    // HSCAN and SSCAN answer `[cursor, [elements]]`.
    private static func scanElements(of reply: RedisReplyValue) -> [RedisReplyValue] {
        if case .array(let parts) = reply, parts.count == 2, case .array(let items) = parts[1] {
            return items
        }
        return elements(of: reply)
    }

    private static func streamEntries(of reply: RedisReplyValue) -> [(id: String, flatFields: [String])] {
        elements(of: reply).compactMap { entry in
            guard case .array(let parts) = entry, parts.count >= 2, case .array(let fields) = parts[1] else { return nil }
            return (id: displayText(parts[0]), flatFields: fields.map(displayText))
        }
    }
}

// The pull side of one export read: a SCAN page at a time, a batch of rows per pull. A read of another database selects
// it for the read and goes back to the session's after.
nonisolated final class RedisExportCursor: @unchecked Sendable {
    private let driver: RedisDriver
    private let query: String
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var scanCursor = RedisScanPage.startCursor
    private var scanned = false
    private var pending: [String] = []
    private var restoreDatabase: Int?
    private var commandRows: [PluginRow]?

    init(driver: RedisDriver, query: String) {
        self.driver = driver
        self.query = query
    }

    deinit {
        guard let restore = restoreDatabase, !finished else { return }
        let driver = driver
        Task { try? await driver.selectDatabase(restore) }
    }

    func next() async throws -> PluginStreamElement? {
        try Task.checkCancellation()
        switch RedisExportRows.request(for: query) {
        case .command:
            return try await nextCommandElement()
        case .keyBrowse(let database):
            return try await nextKeyBrowseElement(database: database)
        }
    }

    // Any other command answers whole: its header on the first pull, its rows on the next.
    private func nextCommandElement() async throws -> PluginStreamElement? {
        if let rows = lock.withLock({ () -> [PluginRow]? in
            defer { commandRows = nil }
            return commandRows
        }) {
            lock.withLock { finished = true }
            return .rows(rows)
        }
        guard lock.withLock({ !started && !finished }) else { return nil }
        lock.withLock { started = true }
        let result = try await driver.execute(query: query)
        let rows = result.rows.map { $0.map(PluginCellValue.fromOptional) }
        lock.withLock {
            if rows.isEmpty {
                finished = true
            } else {
                commandRows = rows
            }
        }
        return .header(PluginStreamHeader(columns: result.columns.map(\.name), columnTypeNames: result.columns.map(\.typeName)))
    }

    private func nextKeyBrowseElement(database: Int?) async throws -> PluginStreamElement? {
        guard lock.withLock({ !finished }) else { return nil }
        if lock.withLock({ !started }) {
            lock.withLock { started = true }
            let session = driver.selectedDatabase
            if let database, database != session {
                try await driver.selectDatabase(database)
                lock.withLock { restoreDatabase = session }
            }
            return .header(PluginStreamHeader(
                columns: RedisExportRows.columns, columnTypeNames: RedisExportRows.columnTypeNames
            ))
        }
        while true {
            try Task.checkCancellation()
            let batch: [String] = lock.withLock {
                let taken = Array(pending.prefix(RedisExportRows.batchSize))
                pending.removeFirst(taken.count)
                return taken
            }
            if !batch.isEmpty {
                let driver = driver
                return .rows(try await RedisExportRows.rows(
                    keys: batch,
                    send: { try await driver.command($0) },
                    readBytes: { try await driver.bulkBytes($0) }
                ))
            }
            let (cursor, wasScanned) = lock.withLock { (scanCursor, scanned) }
            if wasScanned, cursor == RedisScanPage.startCursor {
                try await finish()
                return nil
            }
            let reply = try await driver.command(RedisKeyspaceReads.scanArguments(cursor: cursor))
            let page = try RedisScanPage(reply: reply, command: "SCAN")
            lock.withLock {
                scanned = true
                scanCursor = page.cursor
                pending += page.elements
            }
        }
    }

    private func finish() async throws {
        let restore = lock.withLock { () -> Int? in
            finished = true
            return restoreDatabase
        }
        if let restore {
            try await driver.selectDatabase(restore)
        }
    }
}
