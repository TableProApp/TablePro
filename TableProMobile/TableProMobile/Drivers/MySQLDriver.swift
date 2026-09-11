import CMariaDB
import Foundation
import TableProDatabase
import TableProModels
import TableProMSSQLCore
import TableProPluginKit

nonisolated final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    private let actor = MySQLActor()
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    let ssl: DriverSSLConfiguration
    let databaseType: DatabaseType
    private let connectionEncoding: MySQLConnectionEncoding

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }

    func escapeStringLiteral(_ value: String) -> String {
        SQLEscaping.backslashStringLiteral(value)
    }

    // Set once during connect() before the driver is shared — safe for concurrent reads
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String,
        ssl: DriverSSLConfiguration = .disabled,
        databaseType: DatabaseType = .mysql,
        connectionEncoding: MySQLConnectionEncoding = .utf8
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.ssl = ssl
        self.databaseType = databaseType
        self.connectionEncoding = connectionEncoding
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(
            host: host, port: port, user: user, password: password, database: database,
            ssl: ssl, encoding: connectionEncoding
        )
        serverVersion = await actor.serverVersion()
    }

    func disconnect() async throws {
        await actor.close()
    }

    func ping() async throws -> Bool {
        try await actor.ping()
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
        // MySQL C API does not support async cancel without a second connection.
        // No-op for mobile.
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let beginResult = try await actor.beginStream(query: query)
                    switch beginResult {
                    case .noResult(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                        continuation.finish()
                        return
                    case .rowSet(let columns):
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = await actor.fetchNextRow(options: options, columns: columns) else {
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let raw = try await actor.execute("SHOW FULL TABLES")
        return MySQLTableListing.tables(fromShowFullTables: raw.rows, databaseType: databaseType)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let safe = table.replacingOccurrences(of: "`", with: "``")
        let raw = try await actor.execute("SHOW FULL COLUMNS FROM `\(safe)`")

        return raw.rows.enumerated().compactMap { index, row in
            guard row.count >= 9, let name = row[0], let dataType = row[1] else { return nil }
            let isPK = row[4]?.uppercased().contains("PRI") == true
            let isNullable = row[3]?.uppercased() == "YES"
            let extra = row[6]
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: isPK,
                isNullable: isNullable,
                defaultValue: row[5],
                comment: row[8],
                characterMaxLength: nil,
                ordinalPosition: index,
                isAutoIncrement: ColumnMetadataRules.mySQLIsAutoIncrement(extra: extra),
                isGenerated: ColumnMetadataRules.mySQLIsGenerated(extra: extra)
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let safe = table.replacingOccurrences(of: "`", with: "``")
        let raw = try await actor.execute("SHOW INDEX FROM `\(safe)`")

        var indexMap: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        var order: [String] = []

        for row in raw.rows {
            guard row.count >= 5, let keyName = row[2], let colName = row[4] else { continue }
            if indexMap[keyName] == nil {
                indexMap[keyName] = (
                    isUnique: row[1] == "0",
                    isPrimary: keyName == "PRIMARY",
                    columns: []
                )
                order.append(keyName)
            }
            indexMap[keyName]?.columns.append(colName)
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
        let safe = table.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        let dbSafe = database.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        let query = """
            SELECT
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(dbSafe)'
                AND kcu.TABLE_NAME = '\(safe)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
            """
        let raw = try await actor.execute(query)

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
        let raw = try await actor.execute("SHOW DATABASES")
        return raw.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        let safe = name.replacingOccurrences(of: "`", with: "``")
        _ = try await actor.execute("USE `\(safe)`")
    }

    func switchSchema(to name: String) async throws {
        throw MySQLError.unsupported("MySQL does not support schemas")
    }

    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        _ = try await actor.execute("START TRANSACTION")
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }
}

// MARK: - MySQL Actor (thread-safe C API access)

private actor MySQLActor {
    private var mysql: UnsafeMutablePointer<MYSQL>?

    private static let connectDeadline: DispatchTimeInterval = .seconds(15)

    private var encoding: MySQLConnectionEncoding = .utf8

    func connect(
        host: String, port: Int, user: String, password: String, database: String,
        ssl: DriverSSLConfiguration, encoding: MySQLConnectionEncoding
    ) async throws {
        self.encoding = encoding
        // Close existing connection if reconnecting
        if let mysql { mysql_close(mysql); self.mysql = nil }

        guard let handle = mysql_init(nil) else {
            throw MySQLError.connectionFailed("Failed to initialize MySQL client")
        }

        mysql_options(handle, MYSQL_SET_CHARSET_NAME, MySQLConnectionEncoding.sessionCharacterSetName)

        var timeout: UInt32 = 10
        mysql_options(handle, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        var readTimeout: UInt32 = 30
        mysql_options(handle, MYSQL_OPT_READ_TIMEOUT, &readTimeout)
        var writeTimeout: UInt32 = 30
        mysql_options(handle, MYSQL_OPT_WRITE_TIMEOUT, &writeTimeout)

        var reconnect: my_bool = 0
        mysql_options(handle, MYSQL_OPT_RECONNECT, &reconnect)

        var allowLocalInfile: UInt32 = 0
        mysql_options(handle, MYSQL_OPT_LOCAL_INFILE, &allowLocalInfile)

        var sslEnforce: my_bool = ssl.isEnabled ? 1 : 0
        mysql_options(handle, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
        var sslVerify: my_bool = ssl.verifiesCertificate ? 1 : 0
        mysql_options(handle, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)
        if let caPath = ssl.existingCACertificatePath {
            _ = caPath.withCString { mysql_options(handle, MYSQL_OPT_SSL_CA, $0) }
        }
        if let clientCertPath = ssl.existingClientCertificatePath {
            _ = clientCertPath.withCString { mysql_options(handle, MYSQL_OPT_SSL_CERT, $0) }
        }
        if let clientKeyPath = ssl.existingClientKeyPath {
            _ = clientKeyPath.withCString { mysql_options(handle, MYSQL_OPT_SSL_KEY, $0) }
        }

        guard let portU32 = UInt32(exactly: port), (1...65_535).contains(port) else {
            mysql_close(handle)
            throw MySQLError.connectionFailed(
                "Port \(port) is out of range. Use a value between 1 and 65535."
            )
        }
        // A late call closes the handle it was still using, rather than the caller closing it.
        nonisolated(unsafe) let unsafeHandle = handle
        let connected = try await runCancellableBlocking(
            on: DispatchQueue(label: "com.TablePro.mysql.connect.\(UUID().uuidString)"),
            deadline: Self.connectDeadline,
            timeoutError: {
                MySQLError.connectionFailed(
                    String(localized: "Timed out connecting to the MySQL server.")
                )
            },
            work: {
                mysql_real_connect(
                    unsafeHandle, host, user, password, database, portU32, nil, 0
                ) != nil
            },
            discardLateResult: { _ in mysql_close(unsafeHandle) }
        )

        guard connected else {
            let msg = message(from: handle)
            mysql_close(handle)
            throw MySQLError.connectionFailed(msg)
        }

        guard MariaDBCharacterSet.establishSession(on: handle, encoding: encoding) else {
            let msg = message(from: handle)
            mysql_close(handle)
            throw MySQLError.connectionFailed(msg)
        }

        self.mysql = handle
    }

    func close() {
        if let mysql {
            mysql_close(mysql)
            self.mysql = nil
        }
    }

    func ping() throws -> Bool {
        guard let mysql else { throw MySQLError.notConnected }
        if mysql_ping(mysql) != 0 {
            throw MySQLError.queryFailed(message(from: mysql))
        }
        return true
    }

    private func legacyText(_ value: PluginCellValue) -> String? {
        switch value {
        case .null:
            return nil
        case .text(let text):
            return text
        case .bytes(let data):
            return Self.hexText(data)
        @unknown default:
            return nil
        }
    }

    private static func hexText(_ data: Data) -> String {
        let shown = data.prefix(hexPreviewBytes)
        let hex = shown.map { String(format: "%02X", $0) }.joined()
        return data.count > hexPreviewBytes ? "0x\(hex)…" : "0x\(hex)"
    }

    private static let hexPreviewBytes = 256

    private func message(from mysql: UnsafeMutablePointer<MYSQL>) -> String {
        guard let text = mysql_error(mysql) else { return "" }
        return mysqlSessionText(cString: text, encoding: encoding)
    }

    func serverVersion() -> String? {
        guard let mysql else { return nil }
        return String(cString: mysql_get_server_info(mysql))
    }

    func execute(_ query: String) throws -> RawMySQLResult {
        guard let mysql else { throw MySQLError.notConnected }

        let start = Date()

        guard mysql_real_query(mysql, query, UInt(query.utf8.count)) == 0 else {
            throw MySQLError.queryFailed(message(from: mysql))
        }

        guard let result = mysql_store_result(mysql) else {
            if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
            let raw = mysql_affected_rows(mysql)
            let affected = raw == .max ? 0 : Int(clamping: raw)
            return RawMySQLResult(
                columns: [], columnTypes: [], rows: [],
                rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false
            )
        }
        defer { mysql_free_result(result) }

        let fieldCount = Int(mysql_num_fields(result))
        let described = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(result), count: fieldCount, encoding: encoding
        )
        let columns = described.names
        let columnTypes = described.typeNames

        var rows: [[String?]] = []
        let maxRows = 100_000

        while let row = mysql_fetch_row(result) {
            if rows.count >= maxRows {
                break
            }

            let lengths = mysql_fetch_lengths(result)
            rows.append(described.row(encoding: encoding) { index in
                guard let value = row[index] else { return nil }
                return UnsafeRawBufferPointer(start: value, count: Int(clamping: lengths?[index] ?? 0))
            }.map(legacyText))
        }

        let isTruncated = rows.count >= maxRows
        let affected: Int
        if columns.isEmpty {
            let raw = mysql_affected_rows(mysql)
            affected = raw == .max ? 0 : Int(clamping: raw)
        } else {
            affected = 0
        }
        return RawMySQLResult(
            columns: columns, columnTypes: columnTypes, rows: rows,
            rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: isTruncated
        )
    }

    // MARK: - Streaming

    private var streamingResult: UnsafeMutablePointer<MYSQL_RES>?
    private var streamingColumns: [ColumnInfo] = []
    private var streamingDecoding = MySQLResultColumns()

    func beginStream(query: String) throws -> MySQLBeginStreamResult {
        guard let mysql else { throw MySQLError.notConnected }
        if streamingResult != nil {
            endStream()
        }

        guard mysql_real_query(mysql, query, UInt(query.utf8.count)) == 0 else {
            throw MySQLError.queryFailed(message(from: mysql))
        }

        guard let result = mysql_use_result(mysql) else {
            if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
            let raw = mysql_affected_rows(mysql)
            let affected = raw == .max ? 0 : Int(clamping: raw)
            return .noResult(affectedRows: affected)
        }

        streamingResult = result

        let described = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(result), count: Int(mysql_num_fields(result)), encoding: encoding
        )
        streamingDecoding = described
        let columns = described.names.enumerated().map { index, name in
            ColumnInfo(
                name: name,
                typeName: described.typeNames[index],
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: index
            )
        }
        streamingColumns = columns
        return .rowSet(columns)
    }

    func fetchNextRow(options: StreamOptions, columns: [ColumnInfo]) -> [Cell]? {
        guard let result = streamingResult else { return nil }
        guard let row = mysql_fetch_row(result) else { return nil }

        let lengths = mysql_fetch_lengths(result)
        let values = streamingDecoding.row(encoding: encoding) { index in
            guard let value = row[index] else { return nil }
            return UnsafeRawBufferPointer(start: value, count: Int(clamping: lengths?[index] ?? 0))
        }

        return zip(values, columns).map { value, column in
            let ref = makeCellRef(column: column.name, row: row, options: options, columns: columns)
            switch value {
            case .null:
                return .null
            case .bytes(let data):
                return .binary(byteCount: data.count, ref: ref)
            case .text(let text):
                return Cell.from(
                    legacyValue: text,
                    columnTypeName: column.typeName,
                    options: options,
                    ref: ref
                )
            @unknown default:
                return .null
            }
        }
    }

    func endStream() {
        guard let result = streamingResult else { return }
        while mysql_fetch_row(result) != nil {}
        mysql_free_result(result)
        streamingResult = nil
        streamingColumns = []
        streamingDecoding = MySQLResultColumns()
    }

    private func makeCellRef(column: String, row: MYSQL_ROW, options: StreamOptions, columns: [ColumnInfo]) -> CellRef? {
        guard let lazyContext = options.lazyContext, !lazyContext.primaryKeyColumns.isEmpty else { return nil }

        var pkComponents: [PrimaryKeyComponent] = []
        for pkColumn in lazyContext.primaryKeyColumns {
            guard let columnIndex = columns.firstIndex(where: { $0.name == pkColumn }) else { return nil }
            guard let cValue = row[columnIndex] else { return nil }
            let value = mysqlSessionText(cString: cValue, encoding: encoding)
            pkComponents.append(PrimaryKeyComponent(column: pkColumn, value: value))
        }
        return CellRef(table: lazyContext.table, column: column, primaryKey: pkComponents)
    }
}

nonisolated enum MySQLBeginStreamResult: Sendable {
    case rowSet([ColumnInfo])
    case noResult(affectedRows: Int)
}

nonisolated private struct RawMySQLResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

nonisolated enum MySQLError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "MySQL connection failed: \(msg)"
        case .notConnected: return "Not connected to MySQL database"
        case .queryFailed(let msg): return "MySQL query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
