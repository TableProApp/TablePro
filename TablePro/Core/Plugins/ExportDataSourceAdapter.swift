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

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let query: String
        if let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver,
           let customQuery = pluginDriver.defaultExportQuery(table: table) {
            query = customQuery
        } else {
            let tableRef = qualifiedTableRef(table: table, databaseName: databaseName)
            query = "SELECT * FROM \(tableRef)"
        }
        guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        return pluginDriver.streamRows(query: query)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table)
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
        try await driver.fetchApproximateRowCount(table: table)
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        let sequences = try await driver.fetchDependentSequences(forTable: table)
        return sequences.map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        let types = try await driver.fetchDependentTypes(forTable: table)
        return types.map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
    }

    // MARK: - Helpers

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
