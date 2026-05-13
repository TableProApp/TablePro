import Foundation
import TableProDatabase
import TableProModels
import TableProMSSQLCore

private extension MSSQLRawResult {
    nonisolated func toQueryResult(executionTime: TimeInterval) -> QueryResult {
        let columnInfos = columns.enumerated().map { idx, col in
            ColumnInfo(name: col.name, typeName: col.type.canonicalName, ordinalPosition: idx)
        }
        return QueryResult(
            columns: columnInfos,
            rows: rows.map { row in row.map { $0.stringValue } },
            rowsAffected: affectedRows,
            executionTime: executionTime,
            isTruncated: isTruncated
        )
    }
}

final class MSSQLDriver: DatabaseDriver, @unchecked Sendable {
    private let conn: FreeTDSConnection
    private let host: String

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    nonisolated(unsafe) private(set) var currentSchema: String? = "dbo"
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(connection: DatabaseConnection, password: String?) {
        let options = MSSQLConnectionOptions(
            host: connection.host,
            port: connection.port,
            user: connection.username,
            password: password ?? "",
            database: connection.database,
            schema: MSSQLConnectionOptions.schema(from: connection.additionalFields),
            encryptionFlag: Self.freetdsEncryptionFlag(for: connection.sslConfiguration),
            loginTimeoutSeconds: Int(connection.additionalFields["mssqlLoginTimeout"] ?? "") ?? MSSQLConnectionOptions.defaultLoginTimeoutSeconds
        )
        self.conn = FreeTDSConnection(options: options)
        self.host = connection.host
        self.currentSchema = options.schema
    }

    private static func freetdsEncryptionFlag(for ssl: SSLConfiguration?) -> String {
        guard let mode = ssl?.mode else { return "off" }
        switch mode {
        case .disable: return "off"
        case .require: return "require"
        case .verifyCa, .verifyFull: return "require"
        }
    }

    private var escapedSchema: String {
        (currentSchema ?? "dbo").replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        do {
            try await conn.connect()
        } catch let error as MSSQLCoreError {
            throw mapToConnectionError(error)
        }

        if let serverSchema = try? await runQuery(MSSQLSchemaQueries.currentSchema).rows.first?.first ?? nil,
           !serverSchema.isEmpty {
            currentSchema = serverSchema
        }

        if let version = try? await runQuery(MSSQLSchemaQueries.serverVersion).rows.first?.first ?? nil {
            serverVersion = String(version.prefix(50))
        }
    }

    func disconnect() async throws {
        conn.disconnect()
    }

    func ping() async throws -> Bool {
        _ = try await runQuery(MSSQLSchemaQueries.ping)
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        try await runQuery(query)
    }

    private func runQuery(_ query: String) async throws -> QueryResult {
        let startTime = Date()
        do {
            let raw = try await conn.executeQuery(query)
            return raw.toQueryResult(executionTime: Date().timeIntervalSince(startTime))
        } catch let error as MSSQLCoreError {
            throw mapToConnectionError(error)
        }
    }

    func cancelCurrentQuery() async throws {
        conn.cancelCurrentQuery()
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                let coreStream = AsyncThrowingStream<MSSQLStreamElement, Error> { coreContinuation in
                    Task {
                        do {
                            try await conn.streamQuery(query, continuation: coreContinuation)
                        } catch {
                            coreContinuation.finish(throwing: error)
                        }
                    }
                }
                var emitted = 0
                var headerColumns: [ColumnInfo] = []
                do {
                    for try await element in coreStream {
                        if Task.isCancelled {
                            continuation.yield(.truncated(reason: .cancelled))
                            continuation.finish()
                            return
                        }
                        switch element {
                        case .header(let columns):
                            headerColumns = columns.enumerated().map { idx, col in
                                ColumnInfo(name: col.name, typeName: col.type.canonicalName, ordinalPosition: idx)
                            }
                            continuation.yield(.columns(headerColumns))
                        case .rows(let batch):
                            for row in batch {
                                if emitted >= options.maxRows {
                                    continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                                    continuation.finish()
                                    return
                                }
                                let cells = zip(headerColumns, row).map { columnInfo, rawCell in
                                    cell(from: rawCell, columnTypeName: columnInfo.typeName, options: options)
                                }
                                continuation.yield(.row(Row(cells: cells)))
                                emitted += 1
                            }
                        case .affectedRows(let count):
                            continuation.yield(.rowsAffected(count))
                        }
                    }
                    continuation.finish()
                } catch let error as MSSQLCoreError {
                    continuation.finish(throwing: mapToConnectionError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func cell(from raw: MSSQLRawCell, columnTypeName: String, options: StreamOptions) -> Cell {
        switch raw {
        case .null:
            return .null
        case .string(let value):
            return Cell.from(legacyValue: value, columnTypeName: columnTypeName, options: options)
        case .bytes(let data):
            return .binary(byteCount: data.count, ref: nil)
        }
    }

    // MARK: - Transactions

    func beginTransaction() async throws {
        _ = try await runQuery(MSSQLSchemaQueries.beginTransaction)
    }

    func commitTransaction() async throws {
        _ = try await runQuery(MSSQLSchemaQueries.commitTransaction)
    }

    func rollbackTransaction() async throws {
        _ = try await runQuery(MSSQLSchemaQueries.rollbackTransaction)
    }

    // MARK: - Database & Schema Navigation

    func fetchDatabases() async throws -> [String] {
        let result = try await runQuery(MSSQLSchemaQueries.databases)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        do {
            try await conn.switchDatabase(name)
        } catch let error as MSSQLCoreError {
            throw mapToConnectionError(error)
        }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await runQuery(MSSQLSchemaQueries.schemas)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func switchSchema(to name: String) async throws {
        currentSchema = name
    }

    // MARK: - Table Metadata

    private var effectiveSchema: String { currentSchema ?? "dbo" }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let result = try await runQuery(MSSQLSchemaQueries.tables(schema: schema ?? effectiveSchema))
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseTableRow(row).map {
                TableInfo(name: $0.name, type: $0.isView ? .view : .table)
            }
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let result = try await runQuery(MSSQLSchemaQueries.columns(schema: schema ?? effectiveSchema, table: table))
        return result.rows.enumerated().compactMap { idx, row in
            MSSQLSchemaQueries.parseColumnRow(row).map { parsed in
                ColumnInfo(
                    name: parsed.name,
                    typeName: parsed.displayType,
                    isPrimaryKey: parsed.isPrimaryKey,
                    isNullable: parsed.isNullable,
                    defaultValue: parsed.defaultValue,
                    characterMaxLength: parsed.characterMaxLength,
                    ordinalPosition: idx
                )
            }
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let result = try await runQuery(MSSQLSchemaQueries.indexes(schema: schema ?? effectiveSchema, table: table))
        var byName: [String: (unique: Bool, primary: Bool, cols: [String])] = [:]
        for row in result.rows {
            guard let parsed = MSSQLSchemaQueries.parseIndexRow(row) else { continue }
            if byName[parsed.name] == nil {
                byName[parsed.name] = (parsed.isUnique, parsed.isPrimary, [])
            }
            byName[parsed.name]?.cols.append(parsed.columnName)
        }
        return byName.map { name, info in
            IndexInfo(name: name, columns: info.cols, isUnique: info.unique, isPrimary: info.primary, type: "CLUSTERED")
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let result = try await runQuery(MSSQLSchemaQueries.foreignKeys(schema: schema ?? effectiveSchema, table: table))
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseForeignKeyRow(row).map {
                ForeignKeyInfo(name: $0.constraintName, column: $0.columnName,
                               referencedTable: $0.referencedTable, referencedColumn: $0.referencedColumn)
            }
        }
    }

    // MARK: - Error Mapping

    private func mapToConnectionError(_ error: MSSQLCoreError) -> Error {
        switch error {
        case .notConnected:
            return ConnectionError.notConnected
        case .connectionFailed(let msg):
            return DatabaseError(message: msg)
        case .tlsHandshakeFailed(let msg):
            return DatabaseError(message: "TLS handshake failed: \(msg)")
        case .queryFailed(let msg):
            return DatabaseError(message: msg)
        case .cancelled:
            return CancellationError()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
