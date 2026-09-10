import Foundation
import TableProDatabase
import TableProModels
import TableProOracleCore

nonisolated private extension OracleRawResult {
    nonisolated func toQueryResult(executionTime: TimeInterval) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { index, column in
                ColumnInfo(name: column.name, typeName: column.typeName, ordinalPosition: index)
            },
            rows: rows.map { row in row.map(\.stringValue) },
            rowsAffected: affectedRows,
            executionTime: executionTime,
            isTruncated: isTruncated
        )
    }
}

nonisolated final class OracleDriver: DatabaseDriver, @unchecked Sendable {
    private let core: OracleCoreConnection
    private let host: String
    private let fallbackSchema: String

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    nonisolated(unsafe) private(set) var currentSchema: String?
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(connection: DatabaseConnection, password: String?) {
        let ssl = DriverSSLConfiguration(
            sslEnabled: connection.sslEnabled,
            configuration: connection.sslConfiguration
        )
        core = OracleCoreConnection(options: OracleConnectionOptions(
            host: connection.host,
            port: connection.port,
            user: connection.username,
            password: password ?? "",
            database: connection.database,
            identifierMode: OracleConnectionOptions.identifierMode(from: connection.additionalFields),
            serviceName: connection.additionalFields[OracleConnectionOptions.AdditionalFieldKey.serviceName] ?? "",
            sid: connection.additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] ?? "",
            role: OracleConnectionOptions.role(from: connection.additionalFields),
            tls: ssl.oracleTLSDescription
        ))
        host = connection.host
        fallbackSchema = connection.username.uppercased()
        currentSchema = fallbackSchema
    }

    // MARK: - Connection

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        do {
            try await core.connect()
        } catch let error as OracleCoreError {
            throw mapToConnectionError(error)
        }

        if let schema = try? await runQuery(OracleSchemaQueries.currentSchema).rows.first?.first ?? nil,
           !schema.isEmpty {
            currentSchema = schema
        }

        if let version = try? await runQuery(OracleSchemaQueries.serverVersion).rows.first?.first ?? nil {
            serverVersion = String(version.prefix(60))
        }
    }

    func disconnect() async throws {
        core.disconnect()
    }

    func ping() async throws -> Bool {
        do {
            try await core.ping()
        } catch let error as OracleCoreError {
            throw mapToConnectionError(error)
        }
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        try await runQuery(query)
    }

    private func runQuery(_ query: String) async throws -> QueryResult {
        let startTime = Date()
        do {
            let raw = try await core.executeQuery(query)
            return raw.toQueryResult(executionTime: Date().timeIntervalSince(startTime))
        } catch let error as OracleCoreError {
            throw mapToConnectionError(error)
        }
    }

    private func rawRows(_ query: String) async throws -> [[OracleRawCell]] {
        do {
            return try await core.executeQuery(query).rows
        } catch let error as OracleCoreError {
            throw mapToConnectionError(error)
        }
    }

    func cancelCurrentQuery() async throws {
        core.cancelCurrentQuery()
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                let coreStream = AsyncThrowingStream<OracleStreamElement, Error> { coreContinuation in
                    Task {
                        do {
                            try await core.streamQuery(query, continuation: coreContinuation)
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
                            headerColumns = columns.enumerated().map { index, column in
                                ColumnInfo(name: column.name, typeName: column.typeName, ordinalPosition: index)
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
                        }
                    }
                    continuation.finish()
                } catch let error as OracleCoreError {
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

    private func cell(from raw: OracleRawCell, columnTypeName: String, options: StreamOptions) -> Cell {
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

    func beginTransaction() async throws {}

    func commitTransaction() async throws {
        _ = try await runQuery(OracleSchemaQueries.commitTransaction)
    }

    func rollbackTransaction() async throws {
        _ = try await runQuery(OracleSchemaQueries.rollbackTransaction)
    }

    // MARK: - Database & Schema Navigation

    /// Oracle has no database concept separate from the schema, so the sidebar's
    /// database list and the schema list are the same set of users.
    func fetchDatabases() async throws -> [String] {
        try await fetchSchemas()
    }

    func switchDatabase(to name: String) async throws {
        try await switchSchema(to: name)
    }

    func fetchSchemas() async throws -> [String] {
        try await rawRows(OracleSchemaQueries.users).compactMap { $0.first?.stringValue }
    }

    func switchSchema(to name: String) async throws {
        _ = try await runQuery(OracleSchemaQueries.setCurrentSchema(name))
        currentSchema = name
        core.noteSessionSchema(name)
    }

    // MARK: - Table Metadata

    private var effectiveSchema: String { currentSchema ?? fallbackSchema }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let rows = try await rawRows(OracleSchemaQueries.tables(schema: schema ?? effectiveSchema))
        return rows.compactMap(OracleSchemaQueries.parseTableRow).map {
            TableInfo(name: $0.name, type: $0.isView ? .view : .table)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let rows = try await rawRows(
            OracleSchemaQueries.columns(schema: schema ?? effectiveSchema, table: table)
        )
        return rows.compactMap(OracleSchemaQueries.parseColumnRow).enumerated().map { index, parsed in
            ColumnInfo(
                name: parsed.name,
                typeName: parsed.displayType,
                isPrimaryKey: parsed.isPrimaryKey,
                isNullable: parsed.isNullable,
                defaultValue: nil,
                characterMaxLength: parsed.dataLength.flatMap { Int($0) },
                ordinalPosition: index
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let rows = try await rawRows(
            OracleSchemaQueries.indexes(schema: schema ?? effectiveSchema, table: table)
        )
        var byName: [String: (unique: Bool, primary: Bool, columns: [String])] = [:]
        for row in rows {
            guard let parsed = OracleSchemaQueries.parseIndexRow(row) else { continue }
            if byName[parsed.name] == nil {
                byName[parsed.name] = (parsed.isUnique, parsed.isPrimary, [])
            }
            byName[parsed.name]?.columns.append(parsed.columnName)
        }
        return byName.map { name, info in
            IndexInfo(name: name, columns: info.columns, isUnique: info.unique, isPrimary: info.primary, type: "BTREE")
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let rows = try await rawRows(
            OracleSchemaQueries.foreignKeys(schema: schema ?? effectiveSchema, table: table)
        )
        return rows.compactMap(OracleSchemaQueries.parseForeignKeyRow).map {
            ForeignKeyInfo(
                name: $0.constraintName,
                column: $0.columnName,
                referencedTable: $0.referencedTable,
                referencedColumn: $0.referencedColumn
            )
        }
    }

    // MARK: - Error Mapping

    private func mapToConnectionError(_ error: OracleCoreError) -> Error {
        switch error {
        case .notConnected:
            return ConnectionError.notConnected
        case .cancelled:
            return CancellationError()
        default:
            return DatabaseError(message: error.localizedDescription)
        }
    }
}
