import Foundation
import os
import SQLite3
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLQuoting

nonisolated final class SQLiteDriver: DatabaseDriver, CatalogQuerying, ExportRowStreaming,
    DedicatedTransferConnection, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteDriver")

    private let source: LocalDatabaseFileSource
    private let openMode: LocalDatabaseOpenMode
    private let access: SQLiteAccess
    private let fileAccess = LocalDatabaseFileAccess()
    private let actor = SQLiteActor()

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { String(cString: sqlite3_libversion()) }

    // SQLite ends statement text at a NUL, so a NUL in a value goes in as char(0) between two literals.
    func escapeStringLiteral(_ value: String) -> String {
        value.split(separator: "\0", omittingEmptySubsequences: false)
            .map { SQLQuoting.stringLiteralBody(String($0)) }
            .joined(separator: "'||char(0)||'")
    }

    init(
        source: LocalDatabaseFileSource,
        openMode: LocalDatabaseOpenMode = .existingOnly,
        access: SQLiteAccess = .readWrite
    ) {
        self.source = source
        self.openMode = openMode
        self.access = access
    }

    // MARK: - Connection

    func connect() async throws {
        let path = try fileAccess.begin(source, openMode: openMode)
        do {
            try await actor.open(path: path, flags: openFlags)
        } catch {
            fileAccess.end()
            throw error
        }
    }

    func disconnect() async throws {
        await actor.close()
        fileAccess.end()
        if access == .snapshot, case .file(let url) = source {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var openFlags: Int32 {
        guard access == .readWrite else { return SQLITE_OPEN_READONLY }
        guard openMode == .createNew || source == .inMemory else { return SQLITE_OPEN_READWRITE }
        return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    }

    func ping() async throws -> Bool {
        _ = try await actor.execute("SELECT 1")
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        try await executeParameterized(query: query, parameters: [], typeNames: nil)
    }

    // Bound the way the Mac plugin binds: text as UTF-8 text, bytes as a blob, nothing else rewritten.
    func executeParameterized(query: String, parameters: [PluginCellValue], typeNames: [String?]?) async throws
        -> QueryResult {
        let raw = try await actor.execute(query, parameters: parameters)
        return QueryResult(
            columns: raw.columns.enumerated().map { i, name in
                ColumnInfo(
                    name: name,
                    typeName: i < raw.columnTypes.count ? raw.columnTypes[i] : "",
                    isPrimaryKey: false,
                    isNullable: true,
                    defaultValue: nil,
                    comment: nil,
                    characterMaxLength: nil,
                    ordinalPosition: i
                )
            },
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated,
            statusMessage: nil
        )
    }

    /// Runs off the actor: the actor is busy inside `sqlite3_step` for as long as the statement runs.
    func cancelCurrentQuery() async throws {
        actor.interruptHandle.interrupt()
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        let interruptHandle = actor.interruptHandle
        return AsyncThrowingStream { continuation in
            let stream = SQLiteStreamToken()
            let task = Task {
                do {
                    switch try await actor.beginStream(query: query, stream: stream) {
                    case .commandOk(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                    case .rowSet(let columns):
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = try await actor.fetchNextRow(stream: stream, options: options, columns: columns) else {
                                break
                            }
                            continuation.yield(.row(Row(cells: cells)))
                            emitted += 1
                        }
                        if Task.isCancelled {
                            continuation.yield(.truncated(reason: .cancelled))
                        } else if emitted >= options.maxRows {
                            continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                        }
                        await actor.endStream(stream)
                    }
                    continuation.finish()
                } catch {
                    await actor.endStream(stream)
                    // A cancelled consumer interrupts the step, so the interrupt error is the cancel itself.
                    if error is CancellationError || Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    interruptHandle.interrupt(stream)
                }
            }
        }
    }

    func sessionTransactionState() async -> DriverTransactionState {
        await actor.transactionState()
    }

    // MARK: - Transfer

    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await actor.catalogRows(sql, parameters: parameters)
    }

    // Every row, a blob as its bytes, one batch per pull. A cancel interrupts the step only while this read is the one
    // stepping, so the grid's statement on the same connection runs on.
    func exportRows(query: String, readOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let cursor = SQLiteExportCursor(actor: actor, query: query)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }

    func foreignKeyCheckStatements(enabled: Bool) -> [String] {
        enabled ? SQLiteCatalogReads.foreignKeyEnableStatements : SQLiteCatalogReads.foreignKeyDisableStatements
    }

    // A second reader in rollback-journal mode makes the user's COMMIT fail with SQLITE_BUSY, so outside WAL the
    // transfer reads a copy, made only while the session is idle and the copy fits. Every other case reads the session.
    func openTransferDriver() async throws -> any DatabaseDriver {
        guard access == .readWrite, source != .inMemory,
              await actor.transactionState() == .idle else { return self }
        if await actor.journalMode() == "wal" {
            let reader = SQLiteDriver(source: source, access: .readOnly)
            do {
                try await reader.connect()
                return reader
            } catch {
                Self.logger.warning("A second SQLite reader did not open: \(error.localizedDescription, privacy: .private)")
                return self
            }
        }
        guard let copy = await actor.snapshot(into: Self.snapshotDirectory) else { return self }
        let snapshot = SQLiteDriver(source: .file(copy), access: .snapshot)
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

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let raw = try await actor.execute("""
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT GLOB 'sqlite_*'
            ORDER BY name
            """)

        return raw.rows.compactMap { row in
            guard !row.isEmpty, let name = row[0] else { return nil }
            let kind: TableInfo.TableKind = (row.count > 1 ? row[1] : nil)?.lowercased() == "view" ? .view : .table
            return TableInfo(name: name, type: kind, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let raw = try await actor.execute("PRAGMA table_info(\(SQLQuoting.stringLiteral(table)))")
        let createStatement = try await fetchCreateStatement(table: table)

        let primaryKeyCount = raw.rows.filter { row in
            row.count >= 6 && ColumnMetadataRules.sqliteIsPrimaryKey(pk: row[5])
        }.count

        return raw.rows.enumerated().compactMap { index, row in
            guard row.count >= 6, let name = row[1], let dataType = row[2] else { return nil }
            let isPrimaryKey = ColumnMetadataRules.sqliteIsPrimaryKey(pk: row[5])
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: isPrimaryKey,
                isNullable: row[3] == "0",
                defaultValue: row[4],
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: index,
                isAutoIncrement: ColumnMetadataRules.sqliteIsRowIdAlias(
                    typeName: dataType,
                    isPrimaryKey: isPrimaryKey,
                    primaryKeyCount: primaryKeyCount,
                    createStatement: createStatement
                )
            )
        }
    }

    private func fetchCreateStatement(table: String) async throws -> String? {
        let raw = try await actor.execute(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = \(SQLQuoting.stringLiteral(table))"
        )
        return raw.rows.first?.first ?? nil
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let raw = try await actor.execute("""
            SELECT il.name, il."unique", il.origin, ii.name AS col_name
            FROM pragma_index_list(\(SQLQuoting.stringLiteral(table))) il
            LEFT JOIN pragma_index_info(il.name) ii ON 1=1
            ORDER BY il.seq, ii.seqno
            """)

        var indexMap: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        var order: [String] = []

        for row in raw.rows {
            guard row.count >= 4, let indexName = row[0] else { continue }
            if indexMap[indexName] == nil {
                indexMap[indexName] = (
                    isUnique: row[1] == "1",
                    isPrimary: (row[2] ?? "c") == "pk",
                    columns: []
                )
                order.append(indexName)
            }
            if let col = row[3] {
                indexMap[indexName]?.columns.append(col)
            }
        }

        return order.compactMap { name in
            guard let entry = indexMap[name] else { return nil }
            return IndexInfo(
                name: name,
                columns: entry.columns,
                isUnique: entry.isUnique,
                isPrimary: entry.isPrimary,
                type: "BTREE"
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let raw = try await actor.execute(SQLiteForeignKeyGrouping.foreignKeysQuery(table: table))
        let rows = raw.rows.map { $0.map(PluginCellValue.fromOptional) }
        return SQLiteForeignKeyGrouping.foreignKeys(table: table, fromRows: rows).map { key in
            ForeignKeyInfo(
                name: key.name,
                column: key.column,
                referencedTable: key.referencedTable,
                referencedColumn: key.referencedColumn,
                onDelete: key.onDelete,
                onUpdate: key.onUpdate
            )
        }
    }

    func fetchDatabases() async throws -> [String] { [] }

    func switchDatabase(to name: String) async throws {
        throw SQLiteError.unsupported("SQLite does not support database switching")
    }

    func switchSchema(to name: String) async throws {
        throw SQLiteError.unsupported("SQLite does not support schemas")
    }

    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        _ = try await actor.execute("BEGIN TRANSACTION")
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }
}

// MARK: - Interrupt Handle

/// Identifies one `executeStreaming` call, so the actor and the interrupt handle act only on the
/// statement that call began.
nonisolated final class SQLiteStreamToken: Sendable {}

/// The open connection, reachable without the actor so Stop can interrupt a statement the actor is
/// stepping. SQLite forbids `sqlite3_interrupt` on a connection that is closed or might close before
/// the call returns, so every interrupt and the detach that precedes `sqlite3_close` share one lock.
///
/// An interrupt stops every statement on the connection, and while any statement is active it also
/// stops the next one to start. The data browser and the query editor share a driver, so a stream's
/// consumer interrupts only while its own statement is stepping.
nonisolated final class SQLiteInterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var steppingStream: SQLiteStreamToken?
    private var interruptedDuringStep = false

    func attach(_ db: OpaquePointer) {
        lock.withLock { self.db = db }
    }

    func detach() {
        lock.withLock { db = nil }
    }

    /// The user's Stop, which ends whatever is running.
    func interrupt() {
        lock.withLock {
            guard let db else { return }
            if steppingStream != nil { interruptedDuringStep = true }
            sqlite3_interrupt(db)
        }
    }

    /// Between steps the cancelled producer stops by itself, and an interrupt then would reach the
    /// next statement on the connection instead.
    func interrupt(_ stream: SQLiteStreamToken) {
        lock.withLock {
            guard let db, steppingStream === stream else { return }
            interruptedDuringStep = true
            sqlite3_interrupt(db)
        }
    }

    func beginStep(of stream: SQLiteStreamToken) {
        lock.withLock {
            steppingStream = stream
            interruptedDuringStep = false
        }
    }

    /// Returns whether an interrupt arrived while the step ran.
    func endStep() -> Bool {
        lock.withLock {
            defer {
                steppingStream = nil
                interruptedDuringStep = false
            }
            return interruptedDuringStep
        }
    }
}

// MARK: - SQLite Actor (thread-safe C API access)

private actor SQLiteActor {
    nonisolated let interruptHandle = SQLiteInterruptHandle()
    private var db: OpaquePointer?

    func open(path: String, flags: Int32) throws {
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let db { sqlite3_close(db) }
            self.db = nil
            throw SQLiteError.connectionFailed(msg)
        }
        sqlite3_busy_timeout(db, 5_000)
        if let db { interruptHandle.attach(db) }
    }

    /// `sqlite3_close` refuses a connection with an unfinalized statement and leaves it open, so a
    /// stream still in progress is finalized first.
    func close() {
        interruptHandle.detach()
        finalizeStreamingStatement()
        for statement in exportStatements.values {
            sqlite3_finalize(statement.handle)
        }
        exportStatements.removeAll()
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// SQLite has no implicit transaction to report: autocommit is off from a `BEGIN` or a bare
    /// `SAVEPOINT` until the matching `COMMIT` or `ROLLBACK`.
    func transactionState() -> DriverTransactionState {
        guard let db else { return .unknown }
        return sqlite3_get_autocommit(db) == 0 ? .explicitTransaction : .idle
    }

    func execute(_ query: String, parameters: [PluginCellValue] = []) throws -> RawResult {
        guard let db else { throw SQLiteError.notConnected }

        let start = Date()
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        // Text with only whitespace or comments prepares to no statement, and stepping nothing is a misuse.
        guard stmt != nil else {
            guard parameters.isEmpty else { throw SQLiteError.queryFailed(Self.parameterCountMessage) }
            return RawResult(columns: [], columnTypes: [], rows: [],
                             rowsAffected: 0, executionTime: Date().timeIntervalSince(start), isTruncated: false)
        }
        try Self.bind(parameters, to: stmt, db: db)

        let colCount = sqlite3_column_count(stmt)
        var columns: [String] = []
        var columnTypes: [String] = []

        for i in 0..<colCount {
            columns.append(sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "col_\(i)")
            columnTypes.append(sqlite3_column_decltype(stmt, i).map { String(cString: $0) } ?? "")
        }

        var rows: [[String?]] = []
        let maxRows = 100_000
        var storageClasses = Array(repeating: Set<Int32>(), count: Int(colCount))

        let totalChangesBefore = sqlite3_total_changes64(db)
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            if rows.count >= maxRows {
                return RawResult(columns: columns, columnTypes: Self.reportedTypes(columnTypes, storageClasses), rows: rows,
                                 rowsAffected: 0, executionTime: Date().timeIntervalSince(start), isTruncated: true)
            }

            var row: [String?] = []
            for i in 0..<colCount {
                let storageClass = sqlite3_column_type(stmt, i)
                if storageClass == SQLITE_NULL {
                    row.append(nil)
                    continue
                }
                storageClasses[Int(i)].insert(storageClass)
                if storageClass == SQLITE_BLOB {
                    let bytes = Int(sqlite3_column_bytes(stmt, i))
                    if bytes > 0, let ptr = sqlite3_column_blob(stmt, i) {
                        row.append(Data(bytes: ptr, count: bytes).base64EncodedString())
                    } else {
                        row.append("")
                    }
                } else if let text = Self.text(of: stmt, column: i) {
                    row.append(text)
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        let affected = columns.isEmpty ? changes(of: db, sinceTotal: totalChangesBefore) : 0
        return RawResult(columns: columns, columnTypes: Self.reportedTypes(columnTypes, storageClasses), rows: rows,
                         rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false)
    }

    // A blob reaches the caller as base64 text, so a column with no declared type says BLOB when every value in it is one.
    private static func reportedTypes(_ declared: [String], _ storageClasses: [Set<Int32>]) -> [String] {
        declared.enumerated().map { index, type in
            guard type.isEmpty, index < storageClasses.count, storageClasses[index] == [SQLITE_BLOB] else { return type }
            return "BLOB"
        }
    }

    /// `sqlite3_changes64` keeps the count of the last INSERT, UPDATE or DELETE, so a statement that
    /// wrote nothing, DDL included, would report it again. The total moves only when this one wrote.
    private func changes(of db: OpaquePointer, sinceTotal totalBefore: Int64) -> Int {
        guard sqlite3_total_changes64(db) != totalBefore else { return 0 }
        return Int(sqlite3_changes64(db))
    }

    // MARK: - Binding

    private static let parameterCountMessage = "The statement does not take the values it was given"

    private static func bind(_ parameters: [PluginCellValue], to statement: OpaquePointer?, db: OpaquePointer) throws {
        // A statement run with no values leaves any placeholder NULL, as it always has.
        guard !parameters.isEmpty else { return }
        guard Int(sqlite3_bind_parameter_count(statement)) == parameters.count else {
            throw SQLiteError.queryFailed(parameterCountMessage)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch parameter {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .text(let text):
                result = sqlite3_bind_text64(
                    statement, position, text, sqlite3_uint64(text.utf8.count), transient, UInt8(SQLITE_UTF8)
                )
            case .bytes(let data):
                // An empty Data has no base address, and a null pointer would bind NULL rather than an empty blob.
                let bytes = data.isEmpty ? Data([0]) : data
                result = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(statement, position, buffer.baseAddress, sqlite3_uint64(data.count), transient)
                }
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - Transfer

    // Every row the statement returns, each value as SQLite holds it.
    func catalogRows(_ query: String, parameters: [PluginCellValue]) throws -> PluginQueryResult {
        guard let db else { throw SQLiteError.notConnected }
        let start = Date()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard let stmt else {
            return PluginQueryResult(
                columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0
            )
        }
        try Self.bind(parameters, to: stmt, db: db)
        let header = Self.header(of: stmt)
        var rows: [[PluginCellValue]] = []
        let totalBefore = sqlite3_total_changes64(db)
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            rows.append(Self.values(of: stmt, count: header.columns.count))
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return PluginQueryResult(
            columns: header.columns,
            columnTypeNames: header.columnTypeNames,
            rows: rows,
            rowsAffected: header.columns.isEmpty ? changes(of: db, sinceTotal: totalBefore) : 0,
            executionTime: Date().timeIntervalSince(start)
        )
    }

    private static func header(of stmt: OpaquePointer) -> PluginStreamHeader {
        let count = Int(sqlite3_column_count(stmt))
        let names = (0..<count).map { index in
            sqlite3_column_name(stmt, Int32(index)).map { String(cString: $0) } ?? "col_\(index)"
        }
        let types = (0..<count).map { index in
            sqlite3_column_decltype(stmt, Int32(index)).map { String(cString: $0) } ?? ""
        }
        return PluginStreamHeader(columns: names, columnTypeNames: types)
    }

    private static func values(of stmt: OpaquePointer, count: Int) -> [PluginCellValue] {
        (0..<count).map { index in
            let column = Int32(index)
            switch sqlite3_column_type(stmt, column) {
            case SQLITE_NULL:
                return .null
            case SQLITE_BLOB:
                let byteCount = Int(sqlite3_column_bytes(stmt, column))
                guard byteCount > 0, let pointer = sqlite3_column_blob(stmt, column) else { return .bytes(Data()) }
                return .bytes(Data(bytes: pointer, count: byteCount))
            default:
                return text(of: stmt, column: column).map(PluginCellValue.text) ?? .null
            }
        }
    }

    // Kept apart from `streamingStmt`, so the grid's next page never ends a transfer reading the same connection.
    private var exportStatements: [ObjectIdentifier: (handle: OpaquePointer, columnCount: Int)] = [:]
    // A read whose last batch carried rows: its statement is already finalized, and the next pull ends the stream.
    private var finishedExports: Set<ObjectIdentifier> = []

    func beginExport(query: String, stream: SQLiteStreamToken) throws -> PluginStreamHeader {
        guard let db else { throw SQLiteError.notConnected }
        try Task.checkCancellation()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else { throw SQLiteError.queryFailed("Failed to prepare statement") }
        let header = Self.header(of: stmt)
        exportStatements[ObjectIdentifier(stream)] = (stmt, header.columns.count)
        return header
    }

    // Nil once the statement has no rows left, and the statement is then finalized.
    func nextExportRows(stream: SQLiteStreamToken, limit: Int) throws -> [[PluginCellValue]]? {
        guard let statement = exportStatements[ObjectIdentifier(stream)] else {
            if finishedExports.remove(ObjectIdentifier(stream)) != nil { return nil }
            throw CancellationError()
        }
        var rows: [[PluginCellValue]] = []
        while rows.count < limit {
            let outcome: (result: Int32, interrupted: Bool)
            do {
                outcome = try step(statement.handle, of: stream)
            } catch {
                endExport(stream)
                throw error
            }
            if outcome.interrupted {
                endExport(stream)
                throw CancellationError()
            }
            switch outcome.result {
            case SQLITE_ROW:
                rows.append(Self.values(of: statement.handle, count: statement.columnCount))
            case SQLITE_DONE:
                endExport(stream)
                guard !rows.isEmpty else { return nil }
                finishedExports.insert(ObjectIdentifier(stream))
                return rows
            default:
                let message = String(cString: sqlite3_errmsg(sqlite3_db_handle(statement.handle)))
                endExport(stream)
                throw SQLiteError.queryFailed(message)
            }
        }
        return rows
    }

    func endExport(_ stream: SQLiteStreamToken) {
        finishedExports.remove(ObjectIdentifier(stream))
        guard let statement = exportStatements.removeValue(forKey: ObjectIdentifier(stream)) else { return }
        sqlite3_finalize(statement.handle)
    }

    func journalMode() -> String? {
        pragmaValue("journal_mode")?.lowercased()
    }

    private func pragmaValue(_ name: String) -> String? {
        guard let result = try? execute("PRAGMA \(name)"), let row = result.rows.first, let value = row.first else {
            return nil
        }
        return value
    }

    // Nil when the session holds a transaction, the copy would not fit, or SQLite refuses it; the partial copy is
    // removed. VACUUM INTO copies the main database only, rowids included, as SQLite 3.27 and later make it.
    func snapshot(into directory: URL) -> URL? {
        guard let db, sqlite3_get_autocommit(db) != 0 else { return nil }
        guard let pageCount = pragmaValue("page_count").flatMap(Int64.init),
              let pageSize = pragmaValue("page_size").flatMap(Int64.init) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        guard let free, free > pageCount * pageSize else { return nil }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).sqlite")
        do {
            _ = try execute("VACUUM INTO \(SQLQuoting.stringLiteral(destination.path))")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    // MARK: - Streaming

    /// One statement streams at a time, held with the token of the stream that began it, so the
    /// producer of a stream that a later `beginStream` replaced cannot step or finalize the later one.
    private var streamingStmt: OpaquePointer?
    private var streamingToken: SQLiteStreamToken?

    func beginStream(query: String, stream: SQLiteStreamToken) throws -> SQLiteBeginStreamResult {
        guard let db else { throw SQLiteError.notConnected }
        // Stop can land while the stream waits for the actor, and an interrupt then reaches nothing.
        try Task.checkCancellation()
        finalizeStreamingStatement()

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else {
            throw SQLiteError.queryFailed("Failed to prepare statement")
        }

        let colCount = Int(sqlite3_column_count(stmt))
        if colCount == 0 {
            defer { sqlite3_finalize(stmt) }
            let totalChangesBefore = sqlite3_total_changes64(db)
            let stepResult = try step(stmt, of: stream).result
            guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
                throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            return .commandOk(affectedRows: changes(of: db, sinceTotal: totalChangesBefore))
        }

        var columns: [ColumnInfo] = []
        for i in 0..<colCount {
            let name = sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col_\(i)"
            let typeName = sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? ""
            columns.append(ColumnInfo(
                name: name,
                typeName: typeName,
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: i
            ))
        }
        streamingStmt = stmt
        streamingToken = stream
        return .rowSet(columns)
    }

    /// A stream whose statement is gone, replaced by a later `beginStream` or finalized by a close,
    /// ends as cancelled rather than reading rows that belong to another statement.
    func fetchNextRow(stream: SQLiteStreamToken, options: StreamOptions, columns: [ColumnInfo]) throws -> [Cell]? {
        guard stream === streamingToken, let stmt = streamingStmt else { throw CancellationError() }
        let outcome = try step(stmt, of: stream)
        if outcome.interrupted, outcome.result == SQLITE_ROW {
            // The row was ready before the interrupt took effect, so the interrupt is still pending
            // and would stop the next statement on the connection unless this one ends now.
            finalizeStreamingStatement()
            throw CancellationError()
        }
        switch outcome.result {
        case SQLITE_ROW:
            break
        case SQLITE_DONE:
            return nil
        default:
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }

        var cells: [Cell] = []
        cells.reserveCapacity(columns.count)
        for i in 0..<columns.count {
            let columnIndex = Int32(i)
            let columnType = sqlite3_column_type(stmt, columnIndex)
            switch columnType {
            case SQLITE_NULL:
                cells.append(.null)
            case SQLITE_BLOB:
                let bytes = Int(sqlite3_column_bytes(stmt, columnIndex))
                let ref = makeCellRef(column: columns[i].name, columns: columns, statement: stmt, options: options)
                cells.append(.binary(byteCount: bytes, ref: ref))
            default:
                if let str = Self.text(of: stmt, column: columnIndex) {
                    let ref = makeCellRef(column: columns[i].name, columns: columns, statement: stmt, options: options)
                    // The storage class, not the declared type: a BLOB column can hold text.
                    cells.append(Cell.from(text: str, options: options, ref: ref))
                } else {
                    cells.append(.null)
                }
            }
        }
        return cells
    }

    func endStream(_ stream: SQLiteStreamToken) {
        guard stream === streamingToken else { return }
        finalizeStreamingStatement()
    }

    private func finalizeStreamingStatement() {
        guard let stmt = streamingStmt else { return }
        sqlite3_finalize(stmt)
        streamingStmt = nil
        streamingToken = nil
    }

    /// Marks the step before reading the cancel, so a consumer that leaves at any moment is either
    /// seen here or finds its stream stepping and interrupts it.
    private func step(_ stmt: OpaquePointer, of stream: SQLiteStreamToken) throws -> (result: Int32, interrupted: Bool) {
        interruptHandle.beginStep(of: stream)
        guard !Task.isCancelled else {
            _ = interruptHandle.endStep()
            throw CancellationError()
        }
        let result = sqlite3_step(stmt)
        return (result, interruptHandle.endStep())
    }

    private func makeCellRef(column: String, columns: [ColumnInfo], statement: OpaquePointer, options: StreamOptions) -> CellRef? {
        guard let lazyContext = options.lazyContext, !lazyContext.primaryKeyColumns.isEmpty else { return nil }
        var pkComponents: [PrimaryKeyComponent] = []
        for pkColumn in lazyContext.primaryKeyColumns {
            guard let columnIndex = columns.firstIndex(where: { $0.name == pkColumn }) else { return nil }
            let idx = Int32(columnIndex)
            if sqlite3_column_type(statement, idx) == SQLITE_NULL {
                return nil
            }
            guard let text = Self.text(of: statement, column: idx) else { return nil }
            pkComponents.append(PrimaryKeyComponent(column: pkColumn, value: text))
        }
        return CellRef(table: lazyContext.table, column: column, primaryKey: pkComponents)
    }

    // SQLite keeps a NUL inside text, and a C string ends at the first one.
    private static func text(of statement: OpaquePointer?, column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }
}

nonisolated enum SQLiteAccess: Sendable, Equatable {
    case readWrite
    case readOnly
    // A copy made for one transfer, removed when the driver disconnects.
    case snapshot
}

// The pull side of one export read. A reader that stops before the end finalizes the statement when it lets go.
nonisolated private final class SQLiteExportCursor: @unchecked Sendable {
    private static let batchSize = 500

    private let actor: SQLiteActor
    private let query: String
    private let stream = SQLiteStreamToken()
    private let lock = NSLock()
    private var started = false

    init(actor: SQLiteActor, query: String) {
        self.actor = actor
        self.query = query
    }

    deinit {
        let actor = actor
        let stream = stream
        Task { await actor.endExport(stream) }
    }

    func next() async throws -> PluginStreamElement? {
        let actor = actor
        let stream = stream
        let interruptHandle = actor.interruptHandle
        let isFirst = lock.withLock {
            defer { started = true }
            return !started
        }
        return try await withTaskCancellationHandler {
            if isFirst {
                return .header(try await actor.beginExport(query: query, stream: stream))
            }
            guard let rows = try await actor.nextExportRows(stream: stream, limit: Self.batchSize) else { return nil }
            return .rows(rows)
        } onCancel: {
            interruptHandle.interrupt(stream)
        }
    }
}

nonisolated enum SQLiteBeginStreamResult: Sendable {
    case rowSet([ColumnInfo])
    case commandOk(affectedRows: Int)
}

nonisolated private struct RawResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

nonisolated enum SQLiteError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SQLite connection failed: \(msg)"
        case .notConnected: return "Not connected to SQLite database"
        case .queryFailed(let msg): return "SQLite query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
