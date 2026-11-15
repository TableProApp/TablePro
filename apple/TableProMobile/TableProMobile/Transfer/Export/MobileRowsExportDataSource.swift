import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

// Rows the app already holds whole: selected rows with no key to read them again by, or a result its statement cannot
// be run a second time for.
nonisolated struct ExportRowSet: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]

    init(columns: [String], columnTypeNames: [String], rows: [[PluginCellValue]]) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
    }

    // A cut or binary cell holds only a preview here, and a file must not pass one off as the value.
    init(columns: [ColumnInfo], cells: [[Cell]]) throws(ClipboardExporter.IncompleteValues) {
        let incomplete = ClipboardExporter.incompleteColumns(columns: columns, rows: cells)
        guard incomplete.isEmpty else { throw ClipboardExporter.IncompleteValues(columns: incomplete) }
        self.columns = columns.map(\.name)
        self.columnTypeNames = columns.map(\.typeName)
        self.rows = cells.map { row in
            columns.indices.map { index -> PluginCellValue in
                guard index < row.count, case .text(let value) = row[index] else { return .null }
                return .text(value)
            }
        }
    }

    var count: Int { rows.count }
}

nonisolated final class MobileRowsExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    let lexicalFeatures: SQLLexicalFeatures

    private let rowSet: ExportRowSet
    private let databaseType: DatabaseType
    private let sessionDriver: (any DatabaseDriver)?

    private static let rowsPerElement = 500

    init(rows: ExportRowSet, databaseType: DatabaseType, sessionDriver: (any DatabaseDriver)?) {
        self.rowSet = rows
        self.databaseType = databaseType
        self.sessionDriver = sessionDriver
        self.databaseTypeId = databaseType.rawValue
        self.lexicalFeatures = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: sessionDriver?.settledLexicalFacts
        ).execution.pluginFeatures
    }

    // Pulled a slice at a time, so a writer that stops early never formats the rest.
    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let rowSet = rowSet
        let cursor = RowSliceCursor(total: rowSet.rows.count, sliceSize: Self.rowsPerElement)
        return AsyncThrowingStream(unfolding: {
            switch cursor.next() {
            case nil:
                return nil
            case .header:
                return .header(PluginStreamHeader(
                    columns: rowSet.columns,
                    columnTypeNames: rowSet.columnTypeNames,
                    estimatedRowCount: rowSet.rows.count
                ))
            case .rows(let range):
                return .rows(Array(rowSet.rows[range]))
            }
        })
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        rowSet.rows.count
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ""
    }

    // Held rows have no session to snapshot, so a format's BEGIN or COMMIT passes as a no-op.
    func execute(query: String) async throws -> PluginQueryResult {
        guard ExportSnapshotStatements.isTransactionStatement(query) else {
            throw PluginExportError.exportFailed(String(localized: "These rows are not read from the database again."))
        }
        return ExportSnapshotStatements.noResult
    }

    func quoteIdentifier(_ identifier: String) -> String {
        SQLBuilder.quoteIdentifier(identifier, for: databaseType)
    }

    func escapeStringLiteral(_ value: String) -> String {
        ClipboardExporter.literalBody(value, databaseType: databaseType, driver: sessionDriver)
    }
}

// Hands out the header first, then one row range per pull.
nonisolated final class RowSliceCursor: @unchecked Sendable {
    nonisolated enum Pull: Equatable {
        case header
        case rows(Range<Int>)
    }

    private let lock = NSLock()
    private let total: Int
    private let sliceSize: Int
    private var sentHeader = false
    private var start = 0

    init(total: Int, sliceSize: Int) {
        self.total = total
        self.sliceSize = max(1, sliceSize)
    }

    func next() -> Pull? {
        lock.withLock {
            guard sentHeader else {
                sentHeader = true
                return .header
            }
            guard start < total else { return nil }
            let range = start..<min(start + sliceSize, total)
            start = range.upperBound
            return .rows(range)
        }
    }
}
