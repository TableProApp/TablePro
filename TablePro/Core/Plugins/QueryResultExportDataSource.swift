//
//  QueryResultExportDataSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class QueryResultExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String

    private let columns: [String]
    private let columnTypeNames: [String]
    private let rows: [[PluginCellValue]]

    /// How this engine quotes an identifier and escapes a literal, resolved once from the driver
    /// when there is one and from the engine's declared dialect when there is not. There is no
    /// third answer: writing ANSI for an engine that is not ANSI produces a dump that either will
    /// not parse or, worse, parses and rewrites the data.
    private let quoteIdentifierFn: (String) -> String
    private let escapeStringFn: (String) -> String

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryResultExportDataSource")

    init(tableRows: TableRows, databaseType: DatabaseType, driver: DatabaseDriver?) {
        self.databaseTypeId = databaseType.rawValue
        self.columns = tableRows.columns
        self.columnTypeNames = tableRows.columnTypes.map { $0.rawType ?? "" }
        self.rows = tableRows.rows.map { row in Array(row.values) }

        if let driver {
            self.quoteIdentifierFn = { driver.quoteIdentifier($0) }
            self.escapeStringFn = { driver.escapeStringLiteral($0) }
            return
        }
        /// `resolveSQLDialect` reads the metadata snapshot through `snapshot(for:)`, which remaps a
        /// variant onto the engine it is a variant of. An engine with no SQL dialect at all
        /// (MongoDB, Redis) reaches this only through a format that writes no SQL, so ANSI is a
        /// harmless answer there rather than a wrong one.
        guard let dialect = try? resolveSQLDialect(for: databaseType) else {
            Self.logger.warning(
                "No SQL dialect for \(databaseType.rawValue, privacy: .public), quoting as ANSI")
            self.quoteIdentifierFn = SQLEscaping.quoteIdentifier
            self.escapeStringFn = SQLEscaping.escapeStringLiteral
            return
        }
        self.quoteIdentifierFn = quoteIdentifierFromDialect(dialect)
        self.escapeStringFn = escapeStringLiteralFromDialect(dialect)
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
        quoteIdentifierFn(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        escapeStringFn(value)
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
