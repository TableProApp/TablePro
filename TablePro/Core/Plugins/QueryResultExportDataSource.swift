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

    private init(
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
        databaseTypeId: String,
        quoteIdentifier: @escaping (String) -> String,
        escapeStringLiteral: @escaping (String) -> String
    ) {
        self.databaseTypeId = databaseTypeId
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
        self.quoteIdentifierFn = quoteIdentifier
        self.escapeStringFn = escapeStringLiteral
    }

    convenience init(tableRows: TableRows, databaseType: DatabaseType, driver: DatabaseDriver?) {
        let quoting = Self.quoting(for: databaseType, driver: driver)
        self.init(
            columns: tableRows.columns,
            columnTypeNames: Self.columnTypeNames(of: tableRows),
            rows: tableRows.rows.map { Array($0.values) },
            databaseTypeId: databaseType.rawValue,
            quoteIdentifier: quoting.quoteIdentifier,
            escapeStringLiteral: quoting.escapeStringLiteral
        )
    }

    convenience init(detachedRows tableRows: TableRows, rowIndices: [Int]? = nil, databaseTypeId: String) {
        let rows = rowIndices.map { indices in
            indices.filter { tableRows.rows.indices.contains($0) }.map { Array(tableRows.rows[$0].values) }
        } ?? tableRows.rows.map { Array($0.values) }
        self.init(
            columns: tableRows.columns,
            columnTypeNames: Self.columnTypeNames(of: tableRows),
            rows: rows,
            databaseTypeId: databaseTypeId,
            quoteIdentifier: SQLEscaping.quoteIdentifier,
            escapeStringLiteral: SQLEscaping.escapeStringLiteral
        )
    }

    private static func columnTypeNames(of tableRows: TableRows) -> [String] {
        tableRows.columnTypes.map { $0.rawType ?? "" }
    }

    private static func quoting(
        for databaseType: DatabaseType,
        driver: DatabaseDriver?
    ) -> (quoteIdentifier: (String) -> String, escapeStringLiteral: (String) -> String) {
        if let driver {
            return ({ driver.quoteIdentifier($0) }, { driver.escapeStringLiteral($0) })
        }
        /// `resolveSQLDialect` reads the metadata snapshot through `snapshot(for:)`, which remaps a
        /// variant onto the engine it is a variant of. An engine with no SQL dialect at all
        /// (MongoDB, Redis) reaches this only through a format that writes no SQL, so ANSI is a
        /// harmless answer there rather than a wrong one.
        guard let dialect = try? resolveSQLDialect(for: databaseType) else {
            logger.warning("No SQL dialect for \(databaseType.rawValue, privacy: .public), quoting as ANSI")
            return (SQLEscaping.quoteIdentifier, SQLEscaping.escapeStringLiteral)
        }
        return (quoteIdentifierFromDialect(dialect), escapeStringLiteralFromDialect(dialect))
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
