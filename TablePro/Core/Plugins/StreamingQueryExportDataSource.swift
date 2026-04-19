//
//  StreamingQueryExportDataSource.swift
//  TablePro
//
//  Streaming export data source for query results.
//  Re-executes the query and streams rows directly from the database to the export plugin,
//  bypassing RowBuffer. Allows exporting large result sets without loading all rows into memory.
//

import Foundation
import os
import TableProPluginKit

final class StreamingQueryExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String

    private let query: String
    private let driver: DatabaseDriver
    private let dbType: DatabaseType

    private static let logger = Logger(subsystem: "com.TablePro", category: "StreamingQueryExport")

    init(query: String, driver: DatabaseDriver, databaseType: DatabaseType) {
        self.query = query
        self.driver = driver
        self.dbType = databaseType
        self.databaseTypeId = databaseType.rawValue
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        return pluginDriver.streamRows(query: query)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        nil
    }

    func quoteIdentifier(_ identifier: String) -> String {
        driver.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ""
    }

    func execute(query: String) async throws -> PluginQueryResult {
        let result = try await driver.execute(query: query)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypes.map { $0.rawType ?? "" },
            rows: result.rows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime
        )
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        []
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        []
    }
}
