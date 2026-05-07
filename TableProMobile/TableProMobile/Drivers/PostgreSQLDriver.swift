//
//  PostgreSQLDriver.swift
//  TableProMobile
//
//  PostgreSQL driver conforming to DatabaseDriver directly (no plugin layer).
//

import CLibPQ
import Foundation
import TableProDatabase
import TableProModels

final class PostgreSQLDriver: DatabaseDriver, @unchecked Sendable {
    private let actor = PostgreSQLActor()
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    private let sslEnabled: Bool

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    // Set once during connect()/switchSchema() before the driver is shared — safe for concurrent reads
    nonisolated(unsafe) private(set) var currentSchema: String? = "public"
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(host: String, port: Int, user: String, password: String, database: String, sslEnabled: Bool = false) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslEnabled = sslEnabled
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(host: host, port: port, user: user, password: password, database: database, sslEnabled: sslEnabled)
        serverVersion = await actor.serverVersion()
    }

    func disconnect() async throws {
        await actor.close()
    }

    func ping() async throws -> Bool {
        _ = try await actor.execute("SELECT 1")
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.execute(query)
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

    func cancelCurrentQuery() async throws {
        await actor.cancel()
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let beginResult = try await actor.beginStream(query: query)
                    switch beginResult {
                    case .commandOk(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                        continuation.finish()
                        return
                    case .tuples(let columns):
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = try await actor.fetchNextRow(options: options, columns: columns) else {
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
                        await actor.endStream()
                        continuation.finish()
                    }
                } catch is CancellationError {
                    await actor.endStream()
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    await actor.endStream()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    Task { await actor.cancel() }
                }
            }
        }
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let schemaName = schema ?? "public"
        let safe = schemaName.replacingOccurrences(of: "'", with: "''")
        let raw = try await actor.execute("""
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(safe)'
            ORDER BY table_name
            """)

        return raw.rows.compactMap { row in
            guard row.count >= 2, let name = row[0] else { return nil }
            let typeStr = row[1]?.uppercased() ?? "TABLE"
            let kind: TableInfo.TableKind
            switch typeStr {
            case "VIEW": kind = .view
            case "SYSTEM TABLE": kind = .systemTable
            default: kind = .table
            }
            return TableInfo(name: name, type: kind, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let schemaName = schema ?? "public"
        let safeTbl = table.replacingOccurrences(of: "'", with: "''")
        let safeSchema = schemaName.replacingOccurrences(of: "'", with: "''")

        let raw = try await actor.execute("""
            SELECT
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.character_maximum_length,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk
            FROM information_schema.columns c
            LEFT JOIN (
                SELECT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(safeSchema)'
                    AND tc.table_name = '\(safeTbl)'
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = '\(safeSchema)' AND c.table_name = '\(safeTbl)'
            ORDER BY c.ordinal_position
            """)

        return raw.rows.enumerated().compactMap { index, row in
            guard row.count >= 6, let name = row[0], let dataType = row[1] else { return nil }
            let maxLen = row[4].flatMap { Int($0) }
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: row[5] == "YES",
                isNullable: row[2]?.uppercased() == "YES",
                defaultValue: row[3],
                comment: nil,
                characterMaxLength: maxLen,
                ordinalPosition: index
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let schemaName = schema ?? "public"
        let safeTbl = table.replacingOccurrences(of: "'", with: "''")
        let safeSchema = schemaName.replacingOccurrences(of: "'", with: "''")

        let raw = try await actor.execute("""
            SELECT
                i.relname AS index_name,
                ix.indisunique,
                ix.indisprimary,
                a.attname AS column_name
            FROM pg_index ix
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE n.nspname = '\(safeSchema)' AND t.relname = '\(safeTbl)'
            ORDER BY i.relname, a.attnum
            """)

        var indexMap: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        var order: [String] = []

        for row in raw.rows {
            guard row.count >= 4, let indexName = row[0], let colName = row[3] else { continue }
            if indexMap[indexName] == nil {
                indexMap[indexName] = (
                    isUnique: row[1] == "t",
                    isPrimary: row[2] == "t",
                    columns: []
                )
                order.append(indexName)
            }
            indexMap[indexName]?.columns.append(colName)
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
        let schemaName = schema ?? "public"
        let safeTbl = table.replacingOccurrences(of: "'", with: "''")
        let safeSchema = schemaName.replacingOccurrences(of: "'", with: "''")

        let raw = try await actor.execute("""
            SELECT
                tc.constraint_name,
                kcu.column_name,
                ccu.table_name AS referenced_table,
                ccu.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            JOIN information_schema.constraint_column_usage ccu
                ON tc.constraint_name = ccu.constraint_name
                AND tc.table_schema = ccu.table_schema
            JOIN information_schema.referential_constraints rc
                ON tc.constraint_name = rc.constraint_name
                AND tc.table_schema = rc.constraint_schema
            WHERE tc.constraint_type = 'FOREIGN KEY'
                AND tc.table_schema = '\(safeSchema)'
                AND tc.table_name = '\(safeTbl)'
            ORDER BY tc.constraint_name
            """)

        return raw.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[0],
                  let column = row[1],
                  let refTable = row[2],
                  let refColumn = row[3] else { return nil }
            return ForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4] ?? "NO ACTION",
                onUpdate: row[5] ?? "NO ACTION"
            )
        }
    }

    func fetchDatabases() async throws -> [String] {
        let raw = try await actor.execute(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return raw.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        throw PostgreSQLError.unsupported("PostgreSQL requires a new connection to switch databases")
    }

    func switchSchema(to name: String) async throws {
        let safe = name.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await actor.execute("SET search_path TO \"\(safe)\"")
        currentSchema = name
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name")
        return result.rows.compactMap { $0.first ?? nil }
    }

    func beginTransaction() async throws {
        _ = try await actor.execute("BEGIN")
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }
}

// MARK: - PostgreSQL Actor (thread-safe C API access)

private actor PostgreSQLActor {
    private var conn: OpaquePointer?

    func connect(host: String, port: Int, user: String, password: String, database: String, sslEnabled: Bool = false) throws {
        guard (1...65_535).contains(port) else {
            throw PostgreSQLError.connectionFailed(
                "Port \(port) is out of range. Use a value between 1 and 65535."
            )
        }
        // Close existing connection if reconnecting
        if let conn { PQfinish(conn); self.conn = nil }

        let escapedHost = escapeConnParam(host)
        let escapedUser = escapeConnParam(user)
        let escapedPass = escapeConnParam(password)
        let escapedDb = escapeConnParam(database)
        let sslmode = sslEnabled ? "require" : "disable"

        let connStr = "host='\(escapedHost)' port='\(port)' dbname='\(escapedDb)' " +
            "user='\(escapedUser)' password='\(escapedPass)' connect_timeout='10' sslmode='\(sslmode)'"

        let connection = PQconnectdb(connStr)

        guard PQstatus(connection) == CONNECTION_OK else {
            let msg = connection.flatMap { String(cString: PQerrorMessage($0)) } ?? "Unknown error"
            PQfinish(connection)
            throw PostgreSQLError.connectionFailed(msg)
        }

        self.conn = connection
    }

    private func escapeConnParam(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    func close() {
        if let conn {
            PQfinish(conn)
            self.conn = nil
        }
    }

    func cancel() {
        guard let conn else { return }
        let cancel = PQgetCancel(conn)
        if let cancel {
            var errbuf = [CChar](repeating: 0, count: 256)
            PQcancel(cancel, &errbuf, Int32(errbuf.count))
            PQfreeCancel(cancel)
        }
    }

    func serverVersion() -> String? {
        guard let conn else { return nil }
        let version = PQserverVersion(conn)
        if version == 0 { return nil }
        let major = version / 10000 // swiftlint:disable:this number_separator
        let minor = (version / 100) % 100
        let patch = version % 100
        // PostgreSQL 10+ uses two-component versioning (major.patch)
        // PostgreSQL 9.x and earlier uses three-component versioning (major.minor.patch)
        if major >= 10 {
            return "\(major).\(patch)"
        }
        return "\(major).\(minor).\(patch)"
    }

    func execute(_ query: String) throws -> RawPGResult {
        guard let conn else { throw PostgreSQLError.notConnected }

        let start = Date()
        let result = PQexec(conn, query)
        defer {
            if result != nil { PQclear(result) }
        }

        let status = PQresultStatus(result)

        if status == PGRES_FATAL_ERROR {
            let msg = result.flatMap { String(cString: PQresultErrorMessage($0)) } ?? "Unknown error"
            throw PostgreSQLError.queryFailed(msg)
        }

        if status == PGRES_COMMAND_OK {
            let affectedStr = result.flatMap { String(cString: PQcmdTuples($0)) } ?? "0"
            let affected = Int(affectedStr) ?? 0
            return RawPGResult(
                columns: [], columnTypes: [], rows: [],
                rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false
            )
        }

        guard status == PGRES_TUPLES_OK else {
            let msg = result.flatMap { String(cString: PQresultErrorMessage($0)) } ?? "Unexpected result status"
            throw PostgreSQLError.queryFailed(msg)
        }

        let rowCount = Int(PQntuples(result))
        let colCount = Int(PQnfields(result))

        var columns: [String] = []
        var columnTypes: [String] = []

        for i in 0..<Int32(colCount) {
            let name = PQfname(result, i).map { String(cString: $0) } ?? "col_\(i)"
            columns.append(name)
            let oid = PQftype(result, i)
            columnTypes.append(pgOidToTypeName(oid))
        }

        var rows: [[String?]] = []
        let maxRows = min(rowCount, 100_000)
        let isTruncated = rowCount > 100_000

        for r in 0..<Int32(maxRows) {
            var rowData: [String?] = []
            for c in 0..<Int32(colCount) {
                if PQgetisnull(result, r, c) == 1 {
                    rowData.append(nil)
                } else if let value = PQgetvalue(result, r, c) {
                    rowData.append(String(cString: value))
                } else {
                    rowData.append(nil)
                }
            }
            rows.append(rowData)
        }

        return RawPGResult(
            columns: columns, columnTypes: columnTypes, rows: rows,
            rowsAffected: 0, executionTime: Date().timeIntervalSince(start), isTruncated: isTruncated
        )
    }

    // MARK: - Streaming

    private var pendingResult: OpaquePointer?
    private var streamingFinished = true

    func beginStream(query: String) throws -> PGBeginStreamResult {
        guard let conn else { throw PostgreSQLError.notConnected }
        endStream()

        guard PQsendQuery(conn, query) == 1 else {
            throw PostgreSQLError.queryFailed(String(cString: PQerrorMessage(conn)))
        }
        guard PQsetSingleRowMode(conn) == 1 else {
            drainResults()
            throw PostgreSQLError.queryFailed("Failed to enter single-row streaming mode")
        }
        streamingFinished = false

        guard let firstResult = PQgetResult(conn) else {
            streamingFinished = true
            return .commandOk(affectedRows: 0)
        }

        let status = PQresultStatus(firstResult)
        switch status {
        case PGRES_COMMAND_OK:
            let affectedStr = String(cString: PQcmdTuples(firstResult))
            let affected = Int(affectedStr) ?? 0
            PQclear(firstResult)
            drainResults()
            return .commandOk(affectedRows: affected)
        case PGRES_TUPLES_OK:
            let columns = parseColumns(firstResult)
            PQclear(firstResult)
            drainResults()
            return .tuples(columns)
        case PGRES_SINGLE_TUPLE:
            let columns = parseColumns(firstResult)
            pendingResult = firstResult
            return .tuples(columns)
        default:
            let msg = String(cString: PQresultErrorMessage(firstResult))
            PQclear(firstResult)
            drainResults()
            throw PostgreSQLError.queryFailed(msg)
        }
    }

    func fetchNextRow(options: StreamOptions, columns: [ColumnInfo]) -> [Cell]? {
        guard !streamingFinished else { return nil }

        let result: OpaquePointer?
        if let pending = pendingResult {
            result = pending
            pendingResult = nil
        } else {
            guard let conn else { streamingFinished = true; return nil }
            result = PQgetResult(conn)
        }

        guard let result else {
            streamingFinished = true
            return nil
        }

        let status = PQresultStatus(result)
        if status == PGRES_TUPLES_OK {
            PQclear(result)
            drainResults()
            return nil
        }

        guard status == PGRES_SINGLE_TUPLE else {
            PQclear(result)
            drainResults()
            return nil
        }

        var cells: [Cell] = []
        cells.reserveCapacity(columns.count)
        for c in 0..<columns.count {
            let col = Int32(c)
            if PQgetisnull(result, 0, col) == 1 {
                cells.append(.null)
            } else if let value = PQgetvalue(result, 0, col) {
                let str = String(cString: value)
                let ref = makeCellRef(column: columns[c].name, columns: columns, result: result, options: options)
                cells.append(Cell.from(
                    legacyValue: str,
                    columnTypeName: columns[c].typeName,
                    options: options,
                    ref: ref
                ))
            } else {
                cells.append(.null)
            }
        }
        PQclear(result)
        return cells
    }

    func endStream() {
        drainResults()
        streamingFinished = true
    }

    private func drainResults() {
        if let pending = pendingResult {
            PQclear(pending)
            pendingResult = nil
        }
        guard let conn else { return }
        while let extra = PQgetResult(conn) {
            PQclear(extra)
        }
    }

    private func parseColumns(_ result: OpaquePointer) -> [ColumnInfo] {
        let colCount = Int(PQnfields(result))
        var cols: [ColumnInfo] = []
        for i in 0..<colCount {
            let name = PQfname(result, Int32(i)).map { String(cString: $0) } ?? "col_\(i)"
            let oid = PQftype(result, Int32(i))
            cols.append(ColumnInfo(
                name: name,
                typeName: pgOidToTypeName(oid),
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: i
            ))
        }
        return cols
    }

    private func makeCellRef(column: String, columns: [ColumnInfo], result: OpaquePointer, options: StreamOptions) -> CellRef? {
        guard let lazyContext = options.lazyContext, !lazyContext.primaryKeyColumns.isEmpty else { return nil }
        var pkComponents: [PrimaryKeyComponent] = []
        for pkColumn in lazyContext.primaryKeyColumns {
            guard let columnIndex = columns.firstIndex(where: { $0.name == pkColumn }) else { return nil }
            let col = Int32(columnIndex)
            guard PQgetisnull(result, 0, col) == 0 else { return nil }
            guard let cValue = PQgetvalue(result, 0, col) else { return nil }
            pkComponents.append(PrimaryKeyComponent(column: pkColumn, value: String(cString: cValue)))
        }
        return CellRef(table: lazyContext.table, column: column, primaryKey: pkComponents)
    }
}

enum PGBeginStreamResult: Sendable {
    case tuples([ColumnInfo])
    case commandOk(affectedRows: Int)
}

// MARK: - PostgreSQL OID Type Names

nonisolated private func pgOidToTypeName(_ oid: UInt32) -> String {
    switch oid {
    case 16: return "boolean"
    case 17: return "bytea"
    case 18: return "char"
    case 19: return "name"
    case 20: return "bigint"
    case 21: return "smallint"
    case 23: return "integer"
    case 25: return "text"
    case 26: return "oid"
    case 114: return "json"
    case 142: return "xml"
    case 700: return "real"
    case 701: return "double precision"
    case 869: return "inet"
    // PostgreSQL OID constants — separators would obscure the wire-protocol values
    // swiftlint:disable number_separator
    case 1042: return "char"
    case 1043: return "varchar"
    case 1082: return "date"
    case 1083: return "time"
    case 1114: return "timestamp"
    case 1184: return "timestamptz"
    case 1700: return "numeric"
    case 2950: return "uuid"
    case 3802: return "jsonb"
    // swiftlint:enable number_separator
    default: return "unknown"
    }
}

private struct RawPGResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

enum PostgreSQLError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "PostgreSQL connection failed: \(msg)"
        case .notConnected: return "Not connected to PostgreSQL database"
        case .queryFailed(let msg): return "PostgreSQL query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
