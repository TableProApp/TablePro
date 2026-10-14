import CMariaDB
import Foundation
import os
import TableProCoreTypes
import TableProDatabase
import TableProModels
import TableProMSSQLCore
import TableProPluginKit
import TableProSQLGrammar

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

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLDriver")

    static func sessionSetupStatements(for databaseType: DatabaseType) -> [String] {
        guard databaseType == .oceanbase else { return [] }
        return MySQLServerFlavor.oceanbase(version: nil).queryTimeoutStatements(seconds: 0)
    }

    static func serverFlavor(for databaseType: DatabaseType, banner: String?) -> MySQLServerFlavor {
        switch databaseType {
        case .tidb:
            return .tidb(version: banner.flatMap(MySQLServerFlavor.tidbVersion(fromBanner:)))
        case .oceanbase:
            return .oceanbase(version: banner.flatMap(MySQLServerFlavor.oceanbaseVersion(fromServerVersion:)))
        default:
            return MySQLServerFlavor.fromBanner(banner)
        }
    }

    static func tableListStatement(for databaseType: DatabaseType, banner: String?) -> String {
        let flavor = serverFlavor(for: databaseType, banner: banner)
        return MySQLServerVersion.hasInformationSchema(banner: banner, flavor: flavor) ? "SHOW FULL TABLES" : "SHOW TABLES"
    }

    static func readsForeignKeyCatalog(for databaseType: DatabaseType, banner: String?) -> Bool {
        MySQLServerVersion.hasReferentialConstraintsCatalog(
            banner: banner, flavor: serverFlavor(for: databaseType, banner: banner)
        )
    }

    static func labelsShowTextAsBinary(for databaseType: DatabaseType, banner: String?) -> Bool {
        MySQLServerVersion.labelsShowTextAsBinary(
            banner: banner, flavor: serverFlavor(for: databaseType, banner: banner)
        )
    }

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(
            host: host, port: port, user: user, password: password, database: database,
            ssl: ssl, encoding: connectionEncoding, databaseType: databaseType
        )
        serverVersion = await actor.serverVersion()
        for statement in Self.sessionSetupStatements(for: databaseType) {
            do {
                _ = try await actor.execute(statement)
            } catch {
                Self.logger.warning(
                    "Session setup failed with \(statement, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
                break
            }
        }
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
                var openStream: MySQLStreamID?
                do {
                    switch try await actor.beginStream(query: query) {
                    case .noResult(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                    case .rowSet(let stream, let columns):
                        openStream = stream
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = try await actor.fetchNextRow(
                                stream, options: options, columns: columns
                            ) else {
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
                        openStream = nil
                        try await actor.endStream(stream)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    if let openStream { try? await actor.endStream(openStream) }
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    // The statement already failed with `error`; releasing its result cannot add a second one.
                    if let openStream { try? await actor.endStream(openStream) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let raw = try await actor.execute(Self.tableListStatement(for: databaseType, banner: serverVersion))
        return MySQLTableListing.tables(fromShowTables: raw.rows, databaseType: databaseType)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let safe = table.replacingOccurrences(of: "`", with: "``")
        let raw = try await actor.execute("SHOW FULL COLUMNS FROM `\(safe)`")
        let source = MySQLColumnListing.defaultSource(
            flavor: Self.serverFlavor(for: databaseType, banner: serverVersion),
            banner: serverVersion
        )
        let catalog = await catalogDefaults(table: table, source: source)
        return MySQLColumnListing.columns(fromShowFullColumns: raw.rows, catalogDefaults: catalog, source: source)
    }

    /// A catalog that refuses leaves every default on what `SHOW FULL COLUMNS` reported, as it does on
    /// the Mac, rather than taking the column list down with it.
    private func catalogDefaults(
        table: String,
        source: MySQLColumnListing.DefaultSource
    ) async -> [String: MySQLCatalogDefault] {
        guard let query = MySQLColumnListing.catalogDefaultsQuery(table: table, source: source) else { return [:] }
        do {
            let raw = try await actor.execute(query)
            return MySQLColumnListing.catalogDefaults(fromRows: raw.rows, source: source)
        } catch {
            Self.logger.warning(
                "Column default catalog read failed: \(error.localizedDescription, privacy: .private)"
            )
            return [:]
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

    /// Below 5.1.10 there is no `REFERENTIAL_CONSTRAINTS`, so the keys come from `SHOW CREATE TABLE`, as on
    /// the Mac. An error here would also discard the columns and indexes loaded with the keys.
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        guard Self.readsForeignKeyCatalog(for: databaseType, banner: serverVersion) else {
            return try await declaredForeignKeys(table: table)
        }
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

    private func declaredForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        let safe = table.replacingOccurrences(of: "`", with: "``")
        let raw = try await actor.execute("SHOW CREATE TABLE `\(safe)`")
        guard let row = raw.rows.first, row.count > 1, let ddl = row[1] else { return [] }
        let omittedAction = MySQLServerVersion.omittedForeignKeyAction(
            banner: serverVersion,
            flavor: Self.serverFlavor(for: databaseType, banner: serverVersion)
        )
        return MySQLForeignKeyClause.parse(createTable: ddl, database: database, omittedAction: omittedAction)
            .map { key in
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
        try await beginTransaction(mode: .serverDefault)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        let flavor = Self.serverFlavor(for: databaseType, banner: serverVersion)
        _ = try await actor.execute(flavor.beginTransactionStatement(mode: mode))
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }

    func sessionTransactionState() async -> DriverTransactionState {
        await actor.transactionState()
    }

    /// Databend reports no `NO_BACKSLASH_ESCAPES` flag, so its session says nothing.
    func sessionLexicalFacts() async -> SQLSessionLexicalFacts? {
        guard !Self.serverFlavor(for: databaseType, banner: serverVersion).isDatabend else { return nil }
        return await actor.lexicalFacts()
    }
}

nonisolated enum MySQLSessionTransaction {
    static func state(infoResult: my_bool, serverStatus: UInt32) -> DriverTransactionState {
        guard infoResult == 0 else { return .unknown }
        guard serverStatus & UInt32(SERVER_STATUS_IN_TRANS) != 0 else { return .idle }
        return serverStatus & UInt32(SERVER_STATUS_AUTOCOMMIT) != 0 ? .explicitTransaction : .implicitTransaction
    }
}

// MARK: - MySQL Actor (thread-safe C API access)

private actor MySQLActor {
    private var mysql: UnsafeMutablePointer<MYSQL>?

    private static let connectDeadline: DispatchTimeInterval = .seconds(15)

    private var encoding: MySQLConnectionEncoding = .utf8
    private var errorLanguage: String.Encoding?
    private var showTextIsBinary = false

    func connect(
        host: String, port: Int, user: String, password: String, database: String,
        ssl: DriverSSLConfiguration, encoding: MySQLConnectionEncoding, databaseType: DatabaseType
    ) async throws {
        self.encoding = encoding
        errorLanguage = nil
        showTextIsBinary = false
        close()

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

        let banner = mysql_get_server_info(handle).map { String(cString: $0) }
        showTextIsBinary = MySQLDriver.labelsShowTextAsBinary(for: databaseType, banner: banner)
        errorLanguage = MariaDBCharacterSet.errorLanguage(on: handle)
        self.mysql = handle
    }

    private func binaryStringsAreText(in query: String) -> Bool {
        showTextIsBinary && mysqlStatementListsServerMetadata(query)
    }

    func close() {
        guard let mysql else { return }
        if let result = streamingResult {
            // An open result points at the handle `mysql_close` frees, so it goes first; shutting the socket
            // makes `mysql_free_result` stop reading the rows it would otherwise skip one by one.
            mariadb_cancel(mysql)
            mysql_free_result(result)
            clearStream()
        }
        mysql_close(mysql)
        self.mysql = nil
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
        return MySQLErrorText.decode(cString: text, language: errorLanguage, encoding: encoding)
    }

    func serverVersion() -> String? {
        guard let mysql else { return nil }
        return String(cString: mysql_get_server_info(mysql))
    }

    func transactionState() -> DriverTransactionState {
        guard let mysql else { return .unknown }
        var serverStatus: UInt32 = 0
        let infoResult = mariadb_get_info(mysql, MARIADB_CONNECTION_SERVER_STATUS, &serverStatus)
        return MySQLSessionTransaction.state(infoResult: infoResult, serverStatus: serverStatus)
    }

    /// `NO_BACKSLASH_ESCAPES` from the status flags of the last reply turns the backslash off in both string quotes.
    /// With it off, a double-quoted token is a string or an identifier depending on `ANSI_QUOTES`, which MySQL reports
    /// nowhere, so only the single quote is settled then.
    func lexicalFacts() -> SQLSessionLexicalFacts? {
        guard let mysql else { return nil }
        var serverStatus: UInt32 = 0
        guard mariadb_get_info(mysql, MARIADB_CONNECTION_SERVER_STATUS, &serverStatus) == 0 else { return nil }
        guard serverStatus & UInt32(SERVER_STATUS_NO_BACKSLASH_ESCAPES) != 0 else {
            return SQLSessionLexicalFacts(
                determined: .backslashEscapesInSingleQuotes,
                enabled: .backslashEscapesInSingleQuotes
            )
        }
        return SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
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
            try consumeTrailingResults(of: mysql)
            return RawMySQLResult(
                columns: [], columnTypes: [], rows: [],
                rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false
            )
        }

        let fieldCount = Int(mysql_num_fields(result))
        let described = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(result), count: fieldCount, encoding: encoding,
            binaryStringsAreText: binaryStringsAreText(in: query)
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
        mysql_free_result(result)

        let isTruncated = rows.count >= maxRows
        let affected: Int
        if columns.isEmpty {
            let raw = mysql_affected_rows(mysql)
            affected = raw == .max ? 0 : Int(clamping: raw)
        } else {
            affected = 0
        }
        try consumeTrailingResults(of: mysql)
        return RawMySQLResult(
            columns: columns, columnTypes: columnTypes, rows: rows,
            rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: isTruncated
        )
    }

    // MARK: - Streaming

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLDriver")

    /// `streamingResult`, while set, belongs to the stream `streamGeneration` names.
    private var streamingResult: UnsafeMutablePointer<MYSQL_RES>?
    private var streamGeneration: UInt64 = 0
    private var streamingColumns: [ColumnInfo] = []
    private var streamingDecoding = MySQLResultColumns()

    func beginStream(query: String) throws -> MySQLBeginStreamResult {
        guard let mysql else { throw MySQLError.notConnected }
        endLeftoverStream(of: mysql)
        streamGeneration &+= 1
        let stream = MySQLStreamID(generation: streamGeneration)

        guard mysql_real_query(mysql, query, UInt(query.utf8.count)) == 0 else {
            throw MySQLError.queryFailed(message(from: mysql))
        }

        guard let result = mysql_use_result(mysql) else {
            if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
            let raw = mysql_affected_rows(mysql)
            let affected = raw == .max ? 0 : Int(clamping: raw)
            try consumeTrailingResults(of: mysql)
            return .noResult(affectedRows: affected)
        }

        streamingResult = result

        let described = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(result), count: Int(mysql_num_fields(result)), encoding: encoding,
            binaryStringsAreText: binaryStringsAreText(in: query)
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
        return .rowSet(stream: stream, columns: columns)
    }

    /// A stream that a newer `beginStream` or a close has ended stops short, so it reports as cut off rather
    /// than complete.
    func fetchNextRow(_ stream: MySQLStreamID, options: StreamOptions, columns: [ColumnInfo]) throws -> [Cell]? {
        guard let mysql, stream.generation == streamGeneration, let result = streamingResult else {
            throw CancellationError()
        }
        let errorBefore = mysql_errno(mysql)
        guard let row = mysql_fetch_row(result) else {
            if let failure = fetchFailure(of: mysql, errorBefore: errorBefore) { throw failure }
            return nil
        }

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

    func endStream(_ stream: MySQLStreamID) throws {
        guard let mysql, stream.generation == streamGeneration else { return }
        try releaseStream(of: mysql)
    }

    /// The producer of a superseded stream only learns that its rows were cut off, so an error in the rest of
    /// its statement has no one to reach and is logged.
    private func endLeftoverStream(of mysql: UnsafeMutablePointer<MYSQL>) {
        do {
            try releaseStream(of: mysql)
        } catch {
            Self.logger.warning(
                "A superseded statement failed after its stream ended: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func releaseStream(of mysql: UnsafeMutablePointer<MYSQL>) throws {
        guard let result = streamingResult else { return }
        clearStream()
        try drain(result, of: mysql)
        try consumeTrailingResults(of: mysql)
    }

    private func clearStream() {
        streamingResult = nil
        streamingColumns = []
        streamingDecoding = MySQLResultColumns()
    }

    /// The first result set is the statement's answer, as before. A later one, such as a `CALL` that selects
    /// twice, is read and dropped so the session can take the next command, and an error in one fails the statement.
    private func consumeTrailingResults(of mysql: UnsafeMutablePointer<MYSQL>) throws {
        while mysql_more_results(mysql) != 0 {
            let status = mysql_next_result(mysql)
            if status > 0 { throw MySQLError.queryFailed(message(from: mysql)) }
            if status < 0 { return }
            if let result = mysql_use_result(mysql) {
                try drain(result, of: mysql)
            } else if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
        }
    }

    private func drain(_ result: UnsafeMutablePointer<MYSQL_RES>, of mysql: UnsafeMutablePointer<MYSQL>) throws {
        let errorBefore = mysql_errno(mysql)
        while mysql_fetch_row(result) != nil {}
        let failure = fetchFailure(of: mysql, errorBefore: errorBefore)
        mysql_free_result(result)
        if let failure { throw failure }
    }

    /// `mysql_fetch_row` returns nil both at the end and on an error, and a command refused while the result
    /// was open leaves its own code on the handle, so only a code the fetch set means the rows ended in an error.
    private func fetchFailure(of mysql: UnsafeMutablePointer<MYSQL>, errorBefore: UInt32) -> MySQLError? {
        let code = mysql_errno(mysql)
        guard code != 0, code != errorBefore else { return nil }
        return .queryFailed(message(from: mysql))
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

nonisolated private struct MySQLStreamID: Sendable {
    let generation: UInt64
}

nonisolated private enum MySQLBeginStreamResult: Sendable {
    case rowSet(stream: MySQLStreamID, columns: [ColumnInfo])
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
