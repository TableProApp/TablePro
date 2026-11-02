//
//  QueryResultExportDataSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLQuoting

final class QueryResultExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String

    private let columns: [String]
    private let columnTypeNames: [String]
    private let rows: [[PluginCellValue]]
    // Row index to the row, for rows holding values the page left on the server.
    private let unloadedRows: [Int: Row]
    private let fillUnloaded: UnloadedValueFill?

    private static let filledChunkSize = 50

    /// How this engine quotes an identifier and escapes a literal, resolved once from the driver
    /// when there is one and from the engine's declared dialect when there is not. There is no
    /// third answer: writing ANSI for an engine that is not ANSI produces a dump that either will
    /// not parse or, worse, parses and rewrites the data.
    private let quoteIdentifierFn: (String) -> String
    private let escapeStringFn: (String) -> String
    let lexicalFeatures: SQLLexicalFeatures

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryResultExportDataSource")

    private init(
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
        unloadedRows: [Int: Row] = [:],
        fillUnloaded: UnloadedValueFill? = nil,
        databaseTypeId: String,
        quoteIdentifier: @escaping (String) -> String,
        escapeStringLiteral: @escaping (String) -> String,
        lexicalFeatures: SQLLexicalFeatures = []
    ) {
        self.databaseTypeId = databaseTypeId
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
        self.unloadedRows = unloadedRows
        self.fillUnloaded = fillUnloaded
        self.quoteIdentifierFn = quoteIdentifier
        self.escapeStringFn = escapeStringLiteral
        self.lexicalFeatures = lexicalFeatures
    }

    convenience init(
        tableRows: TableRows,
        databaseType: DatabaseType,
        driver: DatabaseDriver?,
        fillUnloaded: UnloadedValueFill? = nil
    ) {
        let quoting = Self.quoting(for: databaseType, driver: driver)
        var unloadedRows: [Int: Row] = [:]
        for (index, row) in tableRows.rows.enumerated() where row.hasUnloadedValues {
            unloadedRows[index] = row
        }
        self.init(
            columns: tableRows.columns,
            columnTypeNames: Self.columnTypeNames(of: tableRows),
            rows: tableRows.rows.map { Array($0.values) },
            unloadedRows: unloadedRows,
            fillUnloaded: fillUnloaded.map { Self.masking($0, by: tableRows.masks) },
            databaseTypeId: databaseType.rawValue,
            quoteIdentifier: quoting.quoteIdentifier,
            escapeStringLiteral: quoting.escapeStringLiteral,
            lexicalFeatures: quoting.lexicalFeatures
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

    // A value the page left on the server arrives raw, so it takes the same masks as the rows already held.
    private static func masking(_ fill: @escaping UnloadedValueFill, by masks: ColumnMasks) -> UnloadedValueFill {
        guard !masks.isEmpty else { return fill }
        return { rows in
            try await fill(rows).mapValues { cells in
                Dictionary(uniqueKeysWithValues: cells.map { ($0.key, masks.value($0.value, column: $0.key)) })
            }
        }
    }

    private static func columnTypeNames(of tableRows: TableRows) -> [String] {
        tableRows.columnTypes.map { $0.rawType ?? "" }
    }

    private static func quoting(
        for databaseType: DatabaseType,
        driver: DatabaseDriver?
    ) -> (
        quoteIdentifier: (String) -> String,
        escapeStringLiteral: (String) -> String,
        lexicalFeatures: SQLLexicalFeatures
    ) {
        if let driver {
            let features = SQLLexicalResolver.executionFeatures(for: databaseType, session: driver.sessionLexicalState)
            return ({ driver.quoteIdentifier($0) }, { driver.escapeStringLiteral($0) }, features)
        }
        // An engine with no SQL dialect (MongoDB, Redis) reaches this only through a format that writes no SQL.
        guard let dialect = try? resolveSQLDialect(for: databaseType) else {
            logger.warning("No SQL dialect for \(databaseType.rawValue, privacy: .public), quoting as ANSI")
            return (SQLEscaping.quoteIdentifier, SQLEscaping.escapeStringLiteral, [])
        }
        // No session says whether a backslash escapes, so the form no reading of the engine can end early.
        let escapes = SQLLexicalResolver.stringEscapes(for: databaseType)
        var features = SQLLexicalResolver.executionFeatures(for: databaseType, session: nil)
        if escapes.backslashEscapes {
            features.insert(.backslashEscapesInSingleQuotes)
        } else {
            features.remove(.backslashEscapesInSingleQuotes)
        }
        return (
            quoteIdentifierFromDialect(dialect, databaseType: databaseType),
            { SQLQuoting.stringLiteralBody($0, escapes: escapes) },
            features
        )
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let columns = self.columns
        let columnTypeNames = self.columnTypeNames
        let snapshot = self.rows
        if !unloadedRows.isEmpty {
            guard let fillUnloaded else {
                return AsyncThrowingStream { $0.finish(throwing: UnloadedValueError.rowsNotFound) }
            }
            return Self.streamFilling(
                snapshot, unloadedRows: unloadedRows, fill: fillUnloaded,
                header: PluginStreamHeader(columns: columns, columnTypeNames: columnTypeNames, estimatedRowCount: snapshot.count)
            )
        }
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

    // Pulled a chunk at a time, so a chunk is read only once the exporter has written the one before.
    private static func streamFilling(
        _ snapshot: [[PluginCellValue]],
        unloadedRows: [Int: Row],
        fill: @escaping UnloadedValueFill,
        header: PluginStreamHeader
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let cursor = ExportChunkCursor()
        return AsyncThrowingStream(unfolding: {
            switch cursor.next(total: snapshot.count, chunkSize: filledChunkSize) {
            case nil:
                return nil
            case .header:
                return .header(header)
            case .rows(let range):
                return try await filledChunk(range, of: snapshot, unloadedRows: unloadedRows, fill: fill)
            }
        })
    }

    private static func filledChunk(
        _ range: Range<Int>,
        of snapshot: [[PluginCellValue]],
        unloadedRows: [Int: Row],
        fill: UnloadedValueFill
    ) async throws -> PluginStreamElement {
        var chunk = Array(snapshot[range])
        let pending = range.compactMap { unloadedRows[$0] }
        guard !pending.isEmpty else { return .rows(chunk) }
        let filled = try await fill(pending)
        for index in range {
            guard let row = unloadedRows[index] else { continue }
            for column in row.unloadedColumns.keys {
                guard let value = filled[row.id]?[column] else { throw UnloadedValueError.rowsNotFound }
                chunk[index - range.lowerBound][column] = value
            }
        }
        return .rows(chunk)
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

// Hands out the header first, then one row range per pull.
private final class ExportChunkCursor: @unchecked Sendable {
    enum Pull {
        case header
        case rows(Range<Int>)
    }

    private let lock = NSLock()
    private var sentHeader = false
    private var start = 0

    func next(total: Int, chunkSize: Int) -> Pull? {
        lock.withLock {
            guard sentHeader else {
                sentHeader = true
                return .header
            }
            guard start < total else { return nil }
            let range = start..<min(start + chunkSize, total)
            start = range.upperBound
            return .rows(range)
        }
    }
}
