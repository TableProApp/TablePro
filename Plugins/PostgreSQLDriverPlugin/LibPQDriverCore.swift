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
    private var libpqConnection: LibPQPluginConnection?

    var currentSchema: String = "public"
    private var selectedSchema: String?

    var onPostConnect: (@Sendable () async -> Void)?

    var serverVersion: String? { libpqConnection?.serverVersion() }
    var serverVersionNumber: Int32 { libpqConnection?.serverVersionNumber() ?? 0 }

    init(config: DriverConnectionConfig) {
        self.config = config
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
            options: config.additionalFields["connectionOptions"]
        )

        try await pqConn.connect()
        libpqConnection = pqConn

        if let schemaResult = try? await pqConn.executeQuery("SELECT current_schema()"),
           let schema = schemaResult.rows.first?.first?.asText {
            currentSchema = schema
        }

        if let selectedSchema,
           (try? await pqConn.executeQuery(PostgreSQLSchemaQueries.setSearchPath(toSchema: selectedSchema))) != nil {
            currentSchema = selectedSchema
        }

        await onPostConnect?()
    }

    func applySchema(_ schema: String) async throws {
        _ = try await execute(query: PostgreSQLSchemaQueries.setSearchPath(toSchema: schema))
        selectedSchema = schema
        currentSchema = schema
    }

    func disconnect() {
        libpqConnection?.disconnect()
        libpqConnection = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeWithReconnect(query: query, isRetry: false)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard let pqConn = libpqConnection else {
            throw LibPQPluginError.notConnected
        }
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

    func applyQueryTimeout(_ seconds: Int) async throws {
        let ms = seconds * 1_000
        _ = try await execute(query: "SET statement_timeout = '\(ms)'")
    }

    // MARK: - Reconnect

    private func executeWithReconnect(query: String, isRetry: Bool) async throws -> PluginQueryResult {
        guard let pqConn = libpqConnection else {
            throw LibPQPluginError.notConnected
        }

        let startTime = Date()

        do {
            let result = try await pqConn.executeQuery(query)
            return PluginQueryResult(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                rows: result.rows,
                rowsAffected: result.affectedRows,
                executionTime: Date().timeIntervalSince(startTime),
                isTruncated: result.isTruncated
            )
        } catch let error as NSError where !isRetry && Self.isConnectionLostError(error) {
            try await reconnect()
            return try await executeWithReconnect(query: query, isRetry: true)
        }
    }

    private func reconnect() async throws {
        libpqConnection?.disconnect()
        libpqConnection = nil
        try await connect()
    }

    private static func isConnectionLostError(_ error: NSError) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()
        return errorMessage.contains("connection") &&
            (errorMessage.contains("lost") ||
                errorMessage.contains("closed") ||
                errorMessage.contains("no connection") ||
                errorMessage.contains("could not send"))
    }
}

// MARK: - LibPQBackedDriver

protocol LibPQBackedDriver: PluginDatabaseDriver {
    var core: LibPQDriverCore { get }
}

extension LibPQBackedDriver {
    func connect() async throws {
        try await core.connect()
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
    var serverVersion: String? { core.serverVersion }
    var parameterStyle: ParameterStyle { .dollar }

    func escapeLiteral(_ str: String) -> String {
        escapeStringLiteral(str)
    }

    var escapedSchema: String {
        escapeLiteral(core.currentSchema)
    }
}
