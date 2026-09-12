//
//  LibPQDriverCore.swift
//  PostgreSQLDriverPlugin
//
//  Shared libpq connection lifecycle and query execution for every
//  PostgreSQL-wire driver in this plugin (PostgreSQL, Redshift, CockroachDB).
//

import Foundation
import TableProPluginKit

final class LibPQDriverCore: @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let schemaFallbackQueries: [String]
    private let singleConnectionMode: Bool
    private let connectionLock = NSLock()
    private var _libpqConnection: LibPQPluginConnection?
    private var _lostConnection = false

    private var libpqConnection: LibPQPluginConnection? {
        connectionLock.withLock { _libpqConnection }
    }

    var currentSchema: String = "public"
    private var selectedSchema: String?

    var onPostConnect: (@Sendable () async -> Void)?

    /// Set by `LibPQBackedDriver` for the span of one connect, so every driver built on this
    /// core reports its handshake steps without having to thread a parameter through its own
    /// `connect()` and duplicate the setup each one does around it.
    var stageReporter: ConnectionStageReporter?

    var serverVersion: String? { libpqConnection?.serverVersion() }
    /// Latched, because `disconnect()` drops the connection object that knew it and the app asks
    /// this question of the driver it is still holding: the pool closes a lost entry, and the
    /// before-use check pings one, both after something disconnected it.
    var hasLostConnection: Bool {
        connectionLock.withLock {
            if _libpqConnection?.hasLostConnection == true {
                _lostConnection = true
            }
            return _lostConnection
        }
    }
    var serverVersionNumber: Int32 { libpqConnection?.serverVersionNumber() ?? 0 }
    var standardConformingStrings: Bool { libpqConnection?.standardConformingStrings ?? true }
    var isInsideTransactionBlock: Bool { libpqConnection?.isInsideTransactionBlock ?? false }

    init(
        config: DriverConnectionConfig,
        schemaFallbackQueries: [String] = PostgreSQLSchemaQueries.schemaFallbackQueries,
        singleConnectionMode: Bool = false
    ) {
        self.config = config
        self.schemaFallbackQueries = schemaFallbackQueries
        self.singleConnectionMode = singleConnectionMode
    }

    // MARK: - Connection

    func connect() async throws {
        let pqConn = LibPQPluginConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password.isEmpty ? nil : config.password,
            database: config.database,
            sslConfig: config.ssl,
            options: config.additionalFields["connectionOptions"],
            suppressServerSideCancel: singleConnectionMode
        )

        try await pqConn.connect(reportingStage: stageReporter ?? { _ in })
        connectionLock.withLock {
            _libpqConnection = pqConn
            _lostConnection = false
        }

        switch await probeSchema(pqConn, query: PostgreSQLSchemaQueries.currentSchema) {
        case .schema(let schema):
            currentSchema = schema
        case .empty:
            if let fallback = await firstFallbackSchema(pqConn) {
                currentSchema = fallback
                _ = try? await pqConn.executeQuery(PostgreSQLSchemaQueries.setSearchPath(toSchema: fallback))
            }
        case .failed:
            break
        }

        if let selectedSchema,
           (try? await pqConn.executeQuery(PostgreSQLSchemaQueries.setSearchPath(toSchema: selectedSchema))) != nil {
            currentSchema = selectedSchema
        }

        await onPostConnect?()
    }

    private func firstFallbackSchema(_ pqConn: LibPQPluginConnection) async -> String? {
        for query in schemaFallbackQueries {
            if case .schema(let schema) = await probeSchema(pqConn, query: query) {
                return schema
            }
        }
        return nil
    }

    private func probeSchema(_ pqConn: LibPQPluginConnection, query: String) async -> PostgreSQLSchemaProbe {
        let result = try? await pqConn.executeQuery(query)
        return PostgreSQLSchemaQueries.probe(rows: result?.rows)
    }

    func applySchema(_ schema: String) async throws {
        _ = try await execute(query: PostgreSQLSchemaQueries.setSearchPath(toSchema: schema))
        selectedSchema = schema
        currentSchema = schema
    }

    func disconnect() {
        let pqConn = connectionLock.withLock { () -> LibPQPluginConnection? in
            defer { _libpqConnection = nil }
            if _libpqConnection?.hasLostConnection == true {
                _lostConnection = true
            }
            return _libpqConnection
        }
        pqConn?.disconnect()
    }

    func ping() async throws {
        guard let pqConn = libpqConnection else {
            throw LibPQPluginError.notConnected
        }
        _ = try await pqConn.executeQuery("SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let pqConn = try connection()
        let startTime = Date()
        let result = try await pqConn.executeQuery(query)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: result.isTruncated
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let pqConn = try connection()
        let startTime = Date()
        let result = try await pqConn.executeParameterizedQuery(query, parameters: parameters)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: result.isTruncated
        )
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        let pqConn = try connection()
        let startTime = Date()
        let result = try await pqConn.boundedQuery(query, rowCap: rowCap)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            timing: PluginQueryTiming(
                total: Date().timeIntervalSince(startTime),
                firstRow: result.firstRowTime
            ),
            isTruncated: result.isTruncated
        )
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let pqConn = libpqConnection else {
            return AsyncThrowingStream { $0.finish(throwing: LibPQPluginError.notConnected) }
        }
        return pqConn.streamQuery(query)
    }

    func cancelQuery() {
        libpqConnection?.cancelCurrentQuery()
    }

    func setPostgisOidMap(_ map: [UInt32: String]) {
        libpqConnection?.setPostgisOidMap(map)
    }

    func mergeCatalogTypeNames(_ names: [UInt32: String]) {
        libpqConnection?.mergeCatalogTypeNames(names)
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        let ms = seconds * 1_000
        _ = try await execute(query: "SET statement_timeout = '\(ms)'")
    }

    private func connection() throws -> LibPQPluginConnection {
        guard let pqConn = libpqConnection else {
            throw LibPQPluginError.notConnected
        }
        return pqConn
    }
}

// MARK: - LibPQBackedDriver

protocol LibPQBackedDriver: PluginDatabaseDriver {
    var core: LibPQDriverCore { get }
}

extension LibPQBackedDriver {
    /// The new name must be bare. Every libpq engine here rejects a qualified one, because this
    /// statement renames in place and never moves the object; `SET SCHEMA` is the separate verb.
    ///
    /// It lives on the protocol rather than on `PostgreSQLPluginDriver`, because Redshift and
    /// CockroachDB are siblings of that class rather than subclasses: an implementation there
    /// leaves both of them declaring the capability with nothing behind it.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let target = "\(quoteIdentifier(schema ?? core.currentSchema)).\(quoteIdentifier(name))"
        _ = try await execute(query: "ALTER \(objectType) \(target) RENAME TO \(quoteIdentifier(newName))")
    }

    /// Not the database the connection is on: PostgreSQL, Redshift and CockroachDB all answer that
    /// with a refusal, so the app keeps the item off a row it is browsing.
    func renameDatabase(name: String, to newName: String) async throws {
        _ = try await execute(
            query: "ALTER DATABASE \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }

    func renameSchema(name: String, to newName: String) async throws {
        _ = try await execute(
            query: "ALTER SCHEMA \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }

    func connect() async throws {
        try await core.connect()
    }

    /// Routes back through `connect()` rather than calling the core directly, so a driver that
    /// overrides `connect()` to probe catalogs or remap errors still runs its own version.
    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        core.stageReporter = report
        defer { core.stageReporter = nil }
        try await connect()
    }

    func disconnect() {
        core.disconnect()
    }

    func ping() async throws {
        try await core.ping()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await core.execute(query: query)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await core.executeParameterized(query: query, parameters: parameters)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await core.executeBoundedQuery(query: query, rowCap: rowCap)
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        core.streamRows(query: query)
    }

    func cancelQuery() throws {
        core.cancelQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        try await core.applyQueryTimeout(seconds)
    }

    func switchSchema(to schema: String) async throws {
        try await core.applySchema(schema)
    }

    var currentSchema: String? { core.currentSchema }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }

    func beginTransaction() async throws {
        try await beginTransaction(mode: .serverDefault)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        _ = try await execute(query: postgresBeginTransactionStatement(mode: mode))
    }

    var serverVersion: String? { core.serverVersion }
    var hasLostConnection: Bool { core.hasLostConnection }
    var parameterStyle: ParameterStyle { .dollar }

    func escapeStringLiteral(_ value: String) -> String {
        LibPQStringConformance.escape(value, standardConformingStrings: core.standardConformingStrings)
    }

    func escapeLiteral(_ str: String) -> String {
        escapeStringLiteral(str)
    }
}
