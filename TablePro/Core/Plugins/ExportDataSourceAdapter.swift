//
//  ExportDataSourceAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ExportDataSourceAdapter: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    private let driver: DatabaseDriver
    private let dbType: DatabaseType

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportDataSourceAdapter")

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.driver = driver
        self.dbType = databaseType
        self.databaseTypeId = databaseType.rawValue
    }

    private var pluginDriver: (any PluginDatabaseDriver)? {
        (driver as? PluginDriverAdapter)?.schemaPluginDriver
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let pluginDriver else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        let query: String
        if let customQuery = pluginDriver.defaultExportQuery(table: table, schema: exportSchema(for: databaseName)) {
            query = customQuery
        } else {
            query = "SELECT * FROM \(qualifiedTableRef(table: table, databaseName: databaseName))"
        }
        return pluginDriver.streamRows(query: query)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        guard let pluginDriver else {
            return try await driver.fetchTableDDL(table: table)
        }
        return try await pluginDriver.fetchTableDDL(table: table, schema: exportSchema(for: databaseName))
    }

    func execute(query: String) async throws -> PluginQueryResult {
        let result = try await driver.execute(query: query)
        return mapToPluginResult(result)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        driver.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        guard let pluginDriver else {
            return try await driver.fetchApproximateRowCount(table: table)
        }
        return try await pluginDriver.fetchApproximateRowCount(
            table: table,
            schema: exportSchema(for: databaseName)
        )
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        let sequences: [(name: String, ddl: String)]
        if let pluginDriver {
            sequences = try await pluginDriver.fetchDependentSequences(
                table: table,
                schema: exportSchema(for: databaseName)
            )
        } else {
            sequences = try await driver.fetchDependentSequences(forTable: table)
        }
        return sequences.map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        let types: [(name: String, labels: [String])]
        if let pluginDriver {
            types = try await pluginDriver.fetchDependentTypes(
                table: table,
                schema: exportSchema(for: databaseName)
            )
        } else {
            types = try await driver.fetchDependentTypes(forTable: table)
        }
        return types.map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        guard let pluginDriver else { return [] }
        return try await pluginDriver.fetchColumns(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        guard let pluginDriver else { return [:] }
        return try await pluginDriver.fetchAllColumns(schema: exportSchema(for: databaseName))
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        guard let pluginDriver else { return [] }
        return try await pluginDriver.fetchForeignKeys(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        guard let pluginDriver else { return [:] }
        return try await pluginDriver.fetchAllForeignKeys(schema: exportSchema(for: databaseName))
    }

    var tableDDLIncludesForeignKeys: Bool {
        pluginDriver?.tableDDLIncludesForeignKeys ?? false
    }

    // MARK: - Helpers

    /// The export tree names every group after a schema on a schema-aware engine and after a
    /// database everywhere else, so only a schema-aware driver can read that name as its
    /// schema. An empty name means the table sits in the driver's own container.
    func exportSchema(for databaseName: String) -> String? {
        guard let pluginDriver else { return nil }
        guard pluginDriver.supportsSchemas, !databaseName.isEmpty else { return pluginDriver.currentSchema }
        return databaseName
    }

    private func qualifiedTableRef(table: String, databaseName: String) -> String {
        if databaseName.isEmpty {
            return driver.quoteIdentifier(table)
        } else {
            let quotedDb = driver.quoteIdentifier(databaseName)
            let quotedTable = driver.quoteIdentifier(table)
            return "\(quotedDb).\(quotedTable)"
        }
    }

    private func mapToPluginResult(_ result: QueryResult) -> PluginQueryResult {
        PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypes.map { $0.rawType ?? "" },
            rows: result.rows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime
        )
    }
}
