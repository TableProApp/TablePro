//
//  QueryResultExportDataSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// In-memory `PluginExportDataSource` backed by a RowBuffer snapshot.
/// Allows export plugins (CSV, JSON, SQL, XLSX, MQL) to export query results
/// without modification to the plugins themselves.
final class QueryResultExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String

    private let columns: [String]
    private let columnTypeNames: [String]
    private let rows: [[String?]]
    private let driver: DatabaseDriver?

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryResultExportDataSource")

    init(rowBuffer: RowBuffer, databaseType: DatabaseType, driver: DatabaseDriver?) {
        self.databaseTypeId = databaseType.rawValue
        self.driver = driver

        // Snapshot data at init time for thread safety
        self.columns = rowBuffer.columns
        self.columnTypeNames = rowBuffer.columnTypes.map { $0.rawType ?? "" }
        self.rows = rowBuffer.rows
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let columns = self.columns
        let columnTypeNames = self.columnTypeNames
        let snapshot = self.rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(
                columns: columns,
                columnTypeNames: columnTypeNames,
                estimatedRowCount: snapshot.count
            )))
            if !snapshot.isEmpty {
                continuation.yield(.rows(snapshot))
            }
            continuation.finish()
        }
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        rows.count
    }

    func quoteIdentifier(_ identifier: String) -> String {
        if let driver {
            return driver.quoteIdentifier(identifier)
        }
        return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        if let driver {
            return driver.escapeStringLiteral(value)
        }
        return value.replacingOccurrences(of: "'", with: "''")
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ""
    }

    func execute(query: String) async throws -> PluginQueryResult {
        throw ExportError.exportFailed("Execute is not supported for in-memory query result export")
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        []
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        []
    }
}
