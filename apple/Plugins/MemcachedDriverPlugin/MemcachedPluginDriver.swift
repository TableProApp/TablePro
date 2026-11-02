import Foundation
import NIOCore
import os
import TableProMemcachedCore
import TableProPluginKit

/// The text protocol has no command that lists keys. `lru_crawler metadump` (1.4.31 and later) walks every item,
/// so it lists them all; an older server, or one started with the crawler off, only offers `stats cachedump`,
/// which the server caps per slab class, so that list is a sample and the table says so.
final class MemcachedPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MemcachedPluginDriver")

    /// Keys one listing reads before it stops, so a cache holding millions of items cannot exhaust memory.
    static let listingLimit = 1_000_000
    private static let valuesPerRequest = 100

    private let endpoint: MemcachedEndpoint
    private let lock = NSLock()
    private var connection: MemcachedConnection?
    private var _serverVersion: String?
    private var keySource: MemcachedKeySource = .metadump
    private var queryTimeout = 0
    private var shownExpiries: [String: MemcachedKnownExpiry] = [:]
    private var serverClockOffset: Int64 = 0
    private static let shownExpiryLimit = 100_000

    init(config: DriverConnectionConfig) {
        endpoint = MemcachedEndpoint(
            host: config.host,
            port: config.port,
            ssl: config.ssl,
            username: config.username,
            password: config.password,
            connectTimeout: .seconds(10)
        )
    }

    var serverVersion: String? { lock.withLock { _serverVersion } }
    var supportsTransactions: Bool { false }
    var capabilities: PluginCapabilities { [] }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String { name }
    func escapeStringLiteral(_ value: String) -> String { value }

    // MARK: - Connection

    func connect() async throws {
        let opened = MemcachedConnection(endpoint: endpoint)
        do {
            try await opened.open()
            await opened.setRequestTimeout(seconds: lock.withLock { queryTimeout })
            let version = try await Self.version(on: opened)
            let source = try await Self.keySource(on: opened)
            lock.withLock {
                connection = opened
                _serverVersion = version
                keySource = source
            }
        } catch {
            await opened.close()
            throw MemcachedError.wrap(error)
        }
    }

    func disconnect() {
        let existing = lock.withLock { () -> MemcachedConnection? in
            defer { connection = nil }
            return connection
        }
        guard let existing else { return }
        Task { await existing.close() }
    }

    func ping() async throws {
        _ = try await Self.version(on: try liveConnection())
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        lock.withLock { queryTimeout = seconds }
        await lock.withLock({ connection })?.setRequestTimeout(seconds: seconds)
    }

    private func liveConnection() throws -> MemcachedConnection {
        guard let connection = lock.withLock({ connection }) else { throw MemcachedError.notConnected }
        return connection
    }

    private static func version(on connection: MemcachedConnection) async throws -> String {
        guard case .status(let line) = try await connection.send(.version), line.hasPrefix("VERSION ") else {
            throw MemcachedError.unexpectedReply("version")
        }
        return String(line.dropFirst("VERSION ".count))
    }

    /// `stats settings` reports `lru_crawler yes` when the crawler runs. A server too old to report it has none.
    private static func keySource(on connection: MemcachedConnection) async throws -> MemcachedKeySource {
        guard case .lines(let lines, _) = try await connection.send(.stats(arguments: ["settings"])) else {
            return .cachedump
        }
        let crawler = MemcachedKeyListing.statPairs(lines).first { $0.name == "lru_crawler" }?.value
        return crawler == "yes" ? .metadump : .cachedump
    }

    // MARK: - Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let statement = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if statement.lowercased() == "select 1" {
                try await ping()
                return result(columns: ["ok"], types: ["Int32"], rows: [[.text("1")]], started: started)
            }
            if let message = MemcachedBrowseSpec.refusalMessage(statement) {
                throw MemcachedError.refused(message)
            }
            if let spec = MemcachedBrowseSpec.parse(statement) {
                return try await browse(spec, started: started)
            }
            return try await run(try MemcachedCommandParser.parse(statement), started: started)
        } catch {
            throw MemcachedError.wrap(error)
        }
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    private func run(_ command: MemcachedCommand, started: Date) async throws -> PluginQueryResult {
        let connection = try liveConnection()
        if case .metadump = command {
            return try await metadumpResult(command, started: started)
        }
        switch try await connection.send(command) {
        case .values(let values):
            let withCAS: Bool
            switch command {
            case .get(_, let cas), .getAndTouch(_, _, let cas): withCAS = cas
            default: withCAS = false
            }
            let rows: [PluginRow] = values.map { value in
                var row: PluginRow = [.text(value.key), Self.cell(value.data), .text(String(value.flags))]
                if withCAS { row.append(PluginCellValue.fromOptional(value.unique.map(String.init))) }
                return row
            }
            return result(
                columns: ["Key", "Value", "Flags"] + (withCAS ? ["CAS"] : []),
                types: ["String", "String", "Int64"] + (withCAS ? ["Int64"] : []),
                rows: rows, started: started
            )
        case .lines(let lines, _):
            let pairs = MemcachedKeyListing.statPairs(lines)
            guard pairs.count == lines.count else {
                let rows: [PluginRow] = lines.map { [.text($0)] }
                return result(columns: ["Line"], types: ["String"], rows: rows, started: started)
            }
            let rows: [PluginRow] = pairs.map { [.text($0.name), .text($0.value)] }
            return result(columns: ["Name", "Value"], types: ["String", "String"], rows: rows, started: started)
        case .status(let line):
            let affected = ["STORED", "DELETED", "TOUCHED", "OK"].contains(line) || UInt64(line) != nil ? 1 : 0
            return result(
                columns: ["Result"], types: ["String"], rows: [[.text(line)]], affected: affected, started: started
            )
        }
    }

    /// A metadump cannot share a connection with other commands, so it runs on its own.
    private func metadumpResult(_ command: MemcachedCommand, started: Date) async throws -> PluginQueryResult {
        let lines = try await withListingConnection { connection in
            guard case .lines(let lines, _) = try await connection.send(command, lineLimit: Self.listingLimit) else {
                return [String]()
            }
            return lines
        }
        let rows: [PluginRow] = lines.compactMap(MemcachedKeyListing.metadumpEntry).map { entry in
            [
                .text(entry.key),
                PluginCellValue.fromOptional(entry.expiresAt.map(String.init)),
                PluginCellValue.fromOptional(entry.flags.map(String.init)),
            ]
        }
        return result(columns: ["Key", "Expires", "Flags"], types: ["String", "Int64", "Int64"], rows: rows, started: started)
    }

    // MARK: - Browsing

    private func browse(_ spec: MemcachedBrowseSpec, started: Date) async throws -> PluginQueryResult {
        let connection = try liveConnection()
        let serverTime = try await Self.serverTime(on: connection)
        let listed = try await listKeys().filter { !$0.isExpired(at: serverTime) }
        let page = try spec.page(of: listed)

        var values: [String: MemcachedValue] = [:]
        var start = page.startIndex
        while start < page.endIndex {
            try Task.checkCancellation()
            let end = min(start + Self.valuesPerRequest, page.endIndex)
            let keys = page[start ..< end].map(\.key)
            if case .values(let read) = try await connection.send(.get(keys: keys, withCAS: false)) {
                for value in read { values[value.key] = value }
            }
            start = end
        }

        lock.withLock {
            serverClockOffset = serverTime - Int64(Date().timeIntervalSince1970)
            if shownExpiries.count + page.count > Self.shownExpiryLimit { shownExpiries.removeAll() }
            for entry in page { shownExpiries[entry.key] = MemcachedKnownExpiry(expiresAt: entry.expiresAt) }
        }

        let rows: [PluginRow] = page.compactMap { entry in
            guard let value = values[entry.key] else { return nil }
            return [
                .text(entry.key),
                Self.cell(value.data),
                PluginCellValue.fromOptional(entry.secondsLeft(at: serverTime).map(String.init)),
                .text(String(value.flags)),
            ]
        }
        return result(
            columns: MemcachedColumn.allCases.map(\.rawValue),
            types: MemcachedColumn.allCases.map(\.typeName),
            rows: rows, started: started
        )
    }

    private func listKeys() async throws -> [MemcachedKeyEntry] {
        if lock.withLock({ keySource }) == .metadump {
            do {
                return try await withListingConnection { connection in
                    let reply = try await connection.send(.metadump(selector: "all"), lineLimit: Self.listingLimit)
                    guard case .lines(let lines, _) = reply else { return [] }
                    return lines.compactMap(MemcachedKeyListing.metadumpEntry)
                }
            } catch let error as MemcachedServerError where error.kind != .busy && !error.needsAuthentication {
                Self.logger.info("metadump refused, listing with cachedump")
                lock.withLock { keySource = .cachedump }
            }
        }
        return try await cachedumpKeys()
    }

    private func cachedumpKeys() async throws -> [MemcachedKeyEntry] {
        let connection = try liveConnection()
        guard case .lines(let itemStats, _) = try await connection.send(.stats(arguments: ["items"])) else { return [] }
        var entries: [MemcachedKeyEntry] = []
        for slab in MemcachedKeyListing.slabClasses(fromItemStats: itemStats) {
            try Task.checkCancellation()
            let reply = try await connection.send(.stats(arguments: ["cachedump", String(slab), "0"]))
            guard case .lines(let lines, _) = reply else { continue }
            entries += lines.compactMap(MemcachedKeyListing.cachedumpEntry)
            if entries.count >= Self.listingLimit { break }
        }
        return entries
    }

    /// Opens a connection for one listing and closes it after, even when the listing stopped early with the rest
    /// of the reply still on the wire.
    private func withListingConnection<T: Sendable>(
        _ body: (MemcachedConnection) async throws -> T
    ) async throws -> T {
        let listing = MemcachedConnection(endpoint: endpoint)
        do {
            try await listing.open()
            await listing.setRequestTimeout(seconds: lock.withLock { queryTimeout })
            let value = try await body(listing)
            await listing.close()
            return value
        } catch {
            await listing.close()
            throw error
        }
    }

    private static func serverTime(on connection: MemcachedConnection) async throws -> Int64 {
        guard case .lines(let lines, _) = try await connection.send(.stats(arguments: [])),
              let time = MemcachedKeyListing.statPairs(lines).first(where: { $0.name == "time" }).flatMap({ Int64($0.value) })
        else { return Int64(Date().timeIntervalSince1970) }
        return time
    }

    private func stat(_ name: String) async throws -> String? {
        guard case .lines(let lines, _) = try await liveConnection().send(.stats(arguments: [])) else { return nil }
        return MemcachedKeyListing.statPairs(lines).first { $0.name == name }?.value
    }

    // MARK: - Schema

    func fetchDatabases() async throws -> [String] { [MemcachedPlugin.defaultGroupName] }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let bytes = try await stat("bytes").flatMap { Int64($0) }
        return PluginDatabaseMetadata(name: database, tableCount: 1, sizeBytes: bytes)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let count = try await stat("curr_items").flatMap { Int($0) }
        return [PluginTableInfo(
            name: MemcachedPlugin.keysTable, type: "TABLE", rowCount: count, comment: listingComment
        )]
    }

    private var listingComment: String {
        switch lock.withLock({ keySource }) {
        case .metadump:
            return String(localized: "Keys listed with lru_crawler metadump")
        case .cachedump:
            return String(localized: "Keys listed with stats cachedump, which returns a capped sample per slab class")
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        [
            PluginColumnInfo(name: "Key", dataType: "String", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "Value", dataType: "String", isNullable: true),
            PluginColumnInfo(name: "TTL", dataType: "Int64", isNullable: true),
            PluginColumnInfo(name: "Flags", dataType: "Int64", isNullable: false),
        ]
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        [MemcachedPlugin.keysTable: try await fetchColumns(table: MemcachedPlugin.keysTable, schema: schema)]
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await stat("curr_items").flatMap { Int($0) }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        "// Memcached keys\n// \(listingComment)\n// Use 'get <key>' to read a value"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw MemcachedError.refused(String(localized: "Memcached has no views"))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let count = try await stat("curr_items").flatMap { Int64($0) }
        return PluginTableMetadata(tableName: table, rowCount: count, comment: listingComment, engine: "Memcached")
    }

    // MARK: - Grid

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        MemcachedBrowseSpec(limit: limit, offset: offset, ascending: Self.ascending(sortColumns)).statement
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        do {
            var conditions: [MemcachedBrowseSpec.KeyCondition] = []
            for filter in filters {
                conditions.append(try MemcachedBrowseSpec.condition(
                    column: filter.column, op: filter.op, value: filter.value, isCaseSensitive: filter.isCaseSensitive
                ))
            }
            return MemcachedBrowseSpec(
                limit: limit, offset: offset, ascending: Self.ascending(sortColumns),
                conditions: conditions, matchesAll: logicMode.lowercased() != "or"
            ).statement
        } catch {
            return MemcachedBrowseSpec.refusalStatement(MemcachedError.filter(error).pluginErrorMessage)
        }
    }

    private static func ascending(_ sortColumns: [(columnIndex: Int, ascending: Bool)]) -> Bool {
        sortColumns.first { $0.columnIndex == 0 }?.ascending ?? true
    }

    func defaultExportQuery(table: String) -> String? {
        MemcachedBrowseSpec(limit: Self.listingLimit, offset: 0, ascending: true).statement
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["flush_all"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? { nil }

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        let offset = lock.withLock { serverClockOffset }
        let expiries = lock.withLock { shownExpiries }
        let generator = MemcachedStatementGenerator(
            columns: columns,
            now: { Int64(Date().timeIntervalSince1970) + offset },
            knownExpiry: { expiries[$0] }
        )
        return try generator.generateRowWrites(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    // MARK: - Helpers

    private static func cell(_ data: Data) -> PluginCellValue {
        String(data: data, encoding: .utf8).map(PluginCellValue.text) ?? .bytes(data)
    }

    private func result(
        columns: [String], types: [String], rows: [PluginRow], affected: Int = 0, started: Date
    ) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns,
            columnTypeNames: types,
            rows: rows,
            rowsAffected: affected,
            executionTime: Date().timeIntervalSince(started)
        )
    }
}
