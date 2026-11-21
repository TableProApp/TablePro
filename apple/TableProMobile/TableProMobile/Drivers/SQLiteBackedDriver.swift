import Foundation
import os
import SQLite3
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProQuery
import TableProSQLQuoting

// The Mac's SQLite plugin driver over a file this app holds access to: one in its own container, one the user picked
// (security-scoped) or an in-memory database. A transfer reads beside a WAL session or over a snapshot of it. The plugin
// writes no rows of its own, so edits take SQLBuilder's SQL.
nonisolated final class SQLiteBackedDriver: PluginBackedDriver, DedicatedTransferConnection, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteBackedDriver")
    // How long a statement waits on a locked file when the connection sets no query timeout.
    static let defaultBusyTimeoutSeconds = 5

    private let sqlite: SQLitePluginDriver
    private let source: LocalDatabaseFileSource
    private let openMode: LocalDatabaseOpenMode
    private let access: SQLiteAccess
    private let busyTimeoutSeconds: Int
    private let fileAccess = LocalDatabaseFileAccess()

    init(
        source: LocalDatabaseFileSource,
        openMode: LocalDatabaseOpenMode = .existingOnly,
        access: SQLiteAccess = .readWrite,
        busyTimeoutSeconds: Int? = nil
    ) {
        let path = switch source {
        case .inMemory: LocalDatabaseLocation.inMemoryPath
        case .file(let url), .securityScoped(let url): url.path
        }
        // Only the file the app resolved: a connection from the Mac can carry attached databases, extensions or a remote
        // session, none of which this app opens.
        let sqlite = SQLitePluginDriver(
            config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: path),
            backend: SQLiteLocalBackend(path: path, openFlags: Self.openFlags(source: source, openMode: openMode, access: access))
        )
        let busyTimeout = busyTimeoutSeconds ?? Self.defaultBusyTimeoutSeconds
        self.sqlite = sqlite
        self.source = source
        self.openMode = openMode
        self.access = access
        self.busyTimeoutSeconds = busyTimeout
        super.init(
            plugin: sqlite,
            dialedHosts: [],
            queryTimeoutSeconds: busyTimeout,
            readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .sqlite) },
            cancelsRunningRequest: { try? sqlite.cancelQuery() }
        )
    }

    private static func openFlags(source: LocalDatabaseFileSource, openMode: LocalDatabaseOpenMode, access: SQLiteAccess) -> Int32 {
        guard access == .readWrite else { return SQLITE_OPEN_READONLY }
        guard openMode == .createNew || source == .inMemory else { return SQLITE_OPEN_READWRITE }
        return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    }

    override func connect() async throws {
        _ = try fileAccess.begin(source, openMode: openMode)
        do {
            try await super.connect()
        } catch {
            await sqlite.close()
            fileAccess.end()
            throw error
        }
    }

    // Access to a picked file ends only once SQLite has closed it; a transfer's snapshot goes with its reader.
    override func disconnect() async throws {
        await sqlite.close()
        fileAccess.end()
        if access == .snapshot, case .file(let url) = source {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // A transfer's reader runs only its own transfer, so its Stop interrupts whatever it is reading.
    override func cancelCurrentQuery() async throws {
        guard access != .readWrite else { return }
        sqlite.cancelEverything()
    }

    // MARK: - Reads

    // A statement takes its rows in one request and cuts each value while SQLite holds it (`PluginGridCut`); a write
    // reports the rows it changed. The cap never stops a write halfway: SQLite runs a RETURNING statement whole at its
    // first step. A Stop that lands while the request waits for the connection runs nothing.
    override func stream(
        query: String,
        options: StreamOptions,
        bindsToSession: Bool
    ) -> AsyncThrowingStream<StreamElement, Error> {
        let sqlite = sqlite
        let context = statementContext(query)
        let read = Self.gridReader(options: options)
        // One row past the cap, so the read says it stopped there.
        let rowLimit = options.maxRows == .max ? .max : options.maxRows + 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let changed = try await self.exclusively {
                        let sink = PluginGridSink(options: options, continuation: continuation)
                        return try await sqlite.readValues(
                            query: query,
                            context: context,
                            rowLimit: rowLimit,
                            reading: read,
                            header: { sink.begin(columns: $0.columns, typeNames: $0.columnTypeNames) },
                            deliver: { sink.emit($0) }
                        )
                    }
                    if changed != 0 {
                        continuation.yield(.rowsAffected(changed))
                    }
                    continuation.finish()
                } catch {
                    // A Stop interrupts the statement, so its error is the Stop itself.
                    if error is CancellationError || Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func gridReader(options: StreamOptions) -> SQLiteValueReader<PluginGridValue> {
        let cut = PluginGridCut(options: options)
        return { column, value in
            switch value {
            case .null: .null
            case .bytes(let bytes): .bytes(count: bytes.count)
            case .text(let utf8): cut.text(utf8, column: column)
            }
        }
    }

    // A blob reaches these rows as hex text, so a column with no declared type says BLOB when every value in it is one,
    // as a declared BLOB column does.
    override func legacyResult(_ result: PluginQueryResult) -> QueryResult {
        let converted = QueryResult(from: result)
        let blobColumns = Set(result.columnTypeNames.indices.filter { index in
            result.columnTypeNames[index].isEmpty && Self.holdsOnlyBytes(result.rows, at: index)
        })
        guard !blobColumns.isEmpty else { return converted }
        return QueryResult(
            columns: converted.columns.enumerated().map { index, column in
                guard blobColumns.contains(index) else { return column }
                return ColumnInfo(name: column.name, typeName: "BLOB", ordinalPosition: column.ordinalPosition)
            },
            rows: converted.rows,
            rowsAffected: converted.rowsAffected,
            executionTime: converted.executionTime,
            isTruncated: converted.isTruncated,
            statusMessage: converted.statusMessage
        )
    }

    private static func holdsOnlyBytes(_ rows: [[PluginCellValue]], at index: Int) -> Bool {
        var sawBytes = false
        for row in rows where index < row.count {
            switch row[index] {
            case .null: continue
            case .bytes: sawBytes = true
            case .text: return false
            }
        }
        return sawBytes
    }

    // The rowid alias takes the next rowid when an INSERT leaves it out, which the insert form shows as auto-increment.
    override func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let columns = try await super.fetchColumns(table: table, schema: schema)
        let keys = columns.filter { $0.isPrimaryKey }
        guard keys.count == 1, let key = keys.first, ColumnMetadataRules.sqliteIsRowIdAlias(
            typeName: key.typeName, isPrimaryKey: true, primaryKeyCount: 1, createStatement: nil
        ) else { return columns }
        let sqlite = sqlite
        let create = try await inSessionDatabase {
            try await SQLiteCatalogReads.createTableStatement(table: table, schema: schema, run: sqlite.catalogRun)
        }
        guard ColumnMetadataRules.sqliteIsRowIdAlias(
            typeName: key.typeName, isPrimaryKey: true, primaryKeyCount: 1, createStatement: create
        ) else { return columns }
        return columns.map { $0.name == key.name ? $0.autoIncrementing : $0 }
    }

    // MARK: - Transfer

    // A batch per pull with the statement held between pulls, so on the session the grid's statements run between
    // batches. A transfer's own reader reads the same way.
    override func exportRows(query: String, readOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error> {
        var context = statementContext(query)
        context.readOnly = true
        context.enforcesReadOnly = readOnly
        return sqlite.pulledRows(query: query, context: context)
    }

    // A second reader in rollback-journal mode makes the user's COMMIT fail with SQLITE_BUSY, so outside WAL the transfer
    // reads a copy, made only while the session is idle and the copy fits. Every other case reads the session.
    func openTransferDriver() async throws -> any DatabaseDriver {
        guard access == .readWrite, source != .inMemory, await sessionTransactionState() == .idle else { return self }
        if await journalMode() == "wal" {
            let reader = SQLiteBackedDriver(source: source, access: .readOnly, busyTimeoutSeconds: busyTimeoutSeconds)
            do {
                try await reader.connect()
                return reader
            } catch {
                Self.logger.warning("A second SQLite reader did not open: \(error.localizedDescription, privacy: .private)")
                return self
            }
        }
        guard let copy = await snapshot(into: Self.snapshotDirectory) else { return self }
        let snapshot = SQLiteBackedDriver(source: .file(copy), access: .snapshot, busyTimeoutSeconds: busyTimeoutSeconds)
        do {
            try await snapshot.connect()
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: copy)
            Self.logger.warning("A SQLite snapshot did not open: \(error.localizedDescription, privacy: .private)")
            return self
        }
    }

    static var snapshotDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TransferSnapshots", isDirectory: true)
    }

    // A snapshot a closed or killed app left behind; nothing reads one across launches.
    static func removeLeftoverSnapshots() {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }

    private func journalMode() async -> String? {
        let sqlite = sqlite
        return try? await exclusively { try await Self.pragma("journal_mode", on: sqlite) }?.lowercased()
    }

    // Nil when the session holds a transaction, the copy would not fit, or SQLite refuses it; a partial copy is removed.
    // VACUUM INTO copies the main database only, rowids included, as SQLite 3.27 and later make it.
    private func snapshot(into directory: URL) async -> URL? {
        let sqlite = sqlite
        return try? await exclusively { () async throws -> URL? in
            guard await sqlite.sessionTransactionState() == .idle,
                  let pageCount = try await Self.pragma("page_count", on: sqlite).flatMap(Int64.init),
                  let pageSize = try await Self.pragma("page_size", on: sqlite).flatMap(Int64.init) else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            guard let free, free > pageCount * pageSize else { return nil }
            let destination = directory.appendingPathComponent("\(UUID().uuidString).sqlite")
            do {
                _ = try await sqlite.execute(query: "VACUUM INTO \(SQLQuoting.stringLiteral(destination.path))")
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }
    }

    private static func pragma(_ name: String, on sqlite: SQLitePluginDriver) async throws -> String? {
        try await sqlite.execute(query: "PRAGMA \(name)").rows.first?.first?.asText
    }
}

nonisolated enum SQLiteAccess: Sendable, Equatable {
    case readWrite
    case readOnly
    // A copy made for one transfer, removed when the driver disconnects.
    case snapshot
}

nonisolated private extension ColumnInfo {
    var autoIncrementing: ColumnInfo {
        ColumnInfo(
            name: name, typeName: typeName, isPrimaryKey: isPrimaryKey, isNullable: isNullable,
            defaultValue: defaultValue, comment: comment, characterMaxLength: characterMaxLength,
            ordinalPosition: ordinalPosition, isAutoIncrement: true, isGenerated: isGenerated,
            rejectsWrittenValues: rejectsWrittenValues, allowedValues: allowedValues
        )
    }
}
