//
//  StreamingQueryExportDataSource.swift
//  TablePro
//
//  Streaming export data source for query results.
//  Re-executes the query and streams rows directly from the database to the export plugin,
//  bypassing in-memory storage. Allows exporting large result sets without loading all rows into memory.
//

import Foundation
import os
import TableProPluginKit

final class StreamingQueryExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    let lexicalFeatures: SQLLexicalFeatures

    private let query: String
    private let driver: DatabaseDriver
    private let dbType: DatabaseType
    private let safeModeIsReadOnly: Bool
    private let rowCut = OSAllocatedUnfairLock<Int?>(initialState: nil)

    private static let logger = Logger(subsystem: "com.TablePro", category: "StreamingQueryExport")

    // Where the driver stopped the stream at a limit it declared, so the file is partial.
    var driverRowCut: Int? {
        rowCut.withLock { $0 }
    }

    init(query: String, driver: DatabaseDriver, databaseType: DatabaseType, safeModeIsReadOnly: Bool = false) {
        self.query = query
        self.safeModeIsReadOnly = safeModeIsReadOnly
        self.driver = driver
        self.dbType = databaseType
        self.databaseTypeId = databaseType.rawValue
        self.lexicalFeatures = SQLLexicalResolver.executionFeatures(for: databaseType, session: driver.sessionLexicalState)
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let adapter = driver as? PluginDriverAdapter else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        let rowCut = rowCut
        let rows = adapter.streamRows(query: query, safeModeIsReadOnly: safeModeIsReadOnly)
        return ExportRowCut<PluginStreamElement>.reporting(rows, engineCeiling: nil) { limit in
            rowCut.withLock { $0 = limit }
        }
    }

    func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        streamExportRows(table: object.name, databaseName: object.databaseName)
    }

    func streamExportRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        guard let adapter = driver as? PluginDriverAdapter else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        let rowCut = rowCut
        let rows = adapter.streamExportRows(query: query, safeModeIsReadOnly: safeModeIsReadOnly)
        return ExportRowCut<PluginExportStreamElement>.reporting(rows, engineCeiling: nil) { limit in
            rowCut.withLock { $0 = limit }
        }
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
        var mapped = PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypes.map { $0.rawType ?? "" },
            rows: result.rows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime
        )
        mapped.exportDocuments = result.exportDocuments
        mapped.absentCells = result.absentCells
        return mapped
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        []
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        []
    }
}
