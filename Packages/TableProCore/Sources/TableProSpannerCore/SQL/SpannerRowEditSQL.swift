import Foundation
import os

public struct SpannerRowChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case insert
        case update
        case delete
    }

    public struct CellChange: Sendable, Equatable {
        public let column: String
        public let value: SpannerCell

        public init(column: String, value: SpannerCell) {
            self.column = column
            self.value = value
        }
    }

    public let rowIndex: Int
    public let kind: Kind
    public let cellChanges: [CellChange]
    public let originalRow: [SpannerCell]?

    public init(rowIndex: Int, kind: Kind, cellChanges: [CellChange] = [], originalRow: [SpannerCell]? = nil) {
        self.rowIndex = rowIndex
        self.kind = kind
        self.cellChanges = cellChanges
        self.originalRow = originalRow
    }
}

public enum SpannerRowEditSQL {
    public static let defaultSentinel = "__DEFAULT__"

    private static let logger = Logger(subsystem: "com.TablePro", category: "SpannerRowEditSQL")

    public static func statements(
        schema: String,
        table: String,
        columns: [String],
        primaryKey: [String],
        changes: [SpannerRowChange],
        insertedRows: [Int: [SpannerCell]],
        deletedRows: Set<Int>,
        insertedRowIndices: Set<Int>,
        dialect: SpannerDialect
    ) -> [SpannerRenderedStatement]? {
        let target = SpannerRowEditTarget(
            table: dialect.qualifiedName(schema: schema, name: table),
            columns: columns,
            primaryKey: primaryKey,
            dialect: dialect
        )
        var statements: [SpannerRenderedStatement] = []
        for change in changes {
            switch change.kind {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                guard let insert = target.insert(change, row: insertedRows[change.rowIndex]) else {
                    logger.warning("Skipping an insert into a table with no known columns")
                    continue
                }
                statements.append(insert)
            case .update:
                guard !change.cellChanges.isEmpty else { continue }
                guard let update = target.update(change) else { return refuse(change) }
                statements.append(update)
            case .delete:
                guard deletedRows.contains(change.rowIndex) else { continue }
                guard let delete = target.delete(change) else { return refuse(change) }
                statements.append(delete)
            }
        }
        return statements
    }

    public static func identityPreservingInserts(
        schema: String,
        table: String,
        columns: [String],
        rows: [[SpannerCell]],
        dialect: SpannerDialect
    ) -> [SpannerRenderedStatement] {
        let qualifiedTable = dialect.qualifiedName(schema: schema, name: table)
        return rows.compactMap { row in
            let cells = zip(columns, row).map { SpannerRowChange.CellChange(column: $0.0, value: $0.1) }
            guard !cells.isEmpty else { return nil }
            return SpannerRowEditTarget.insertStatement(table: qualifiedTable, cells: cells, dialect: dialect)
        }
    }

    private static func refuse(_ change: SpannerRowChange) -> [SpannerRenderedStatement]? {
        logger.warning("Refusing a row change that cannot be keyed by the primary key (row \(change.rowIndex, privacy: .public))")
        return nil
    }
}

internal struct SpannerRowEditTarget {
    let table: String
    let columns: [String]
    let primaryKey: [String]
    let dialect: SpannerDialect

    func insert(_ change: SpannerRowChange, row: [SpannerCell]?) -> SpannerRenderedStatement? {
        let cells = row.map { zip(columns, $0).map { SpannerRowChange.CellChange(column: $0.0, value: $0.1) } }
            ?? Self.lastValuePerColumn(change.cellChanges)
        let written = cells.filter { !Self.isDefaultSentinel($0.value) }
        guard written.isEmpty else {
            return Self.insertStatement(table: table, cells: written, dialect: dialect)
        }
        guard let firstColumn = columns.first else { return nil }
        return SpannerRenderedStatement(
            sql: "INSERT INTO \(table) (\(dialect.quoteIdentifier(firstColumn))) VALUES (DEFAULT)"
        )
    }

    func update(_ change: SpannerRowChange) -> SpannerRenderedStatement? {
        guard let key = keyPredicate(for: change) else { return nil }
        var parameters: [SpannerCell] = []
        let assignments = Self.lastValuePerColumn(change.cellChanges).map { cell in
            let column = dialect.quoteIdentifier(cell.column)
            guard !Self.isDefaultSentinel(cell.value) else { return "\(column) = DEFAULT" }
            parameters.append(cell.value)
            return "\(column) = ?"
        }
        return SpannerRenderedStatement(
            sql: "UPDATE \(table) SET \(assignments.joined(separator: ", ")) WHERE \(key.sql)",
            parameters: parameters + key.parameters
        )
    }

    func delete(_ change: SpannerRowChange) -> SpannerRenderedStatement? {
        guard let key = keyPredicate(for: change) else { return nil }
        return SpannerRenderedStatement(sql: "DELETE FROM \(table) WHERE \(key.sql)", parameters: key.parameters)
    }

    static func insertStatement(
        table: String,
        cells: [SpannerRowChange.CellChange],
        dialect: SpannerDialect
    ) -> SpannerRenderedStatement {
        let names = cells.map { dialect.quoteIdentifier($0.column) }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: cells.count).joined(separator: ", ")
        return SpannerRenderedStatement(
            sql: "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))",
            parameters: cells.map(\.value)
        )
    }

    private func keyPredicate(for change: SpannerRowChange) -> (sql: String, parameters: [SpannerCell])? {
        guard !primaryKey.isEmpty, let originalRow = change.originalRow else { return nil }
        var terms: [String] = []
        var parameters: [SpannerCell] = []
        for keyColumn in primaryKey {
            guard let index = columns.firstIndex(of: keyColumn), index < originalRow.count else { return nil }
            let quoted = dialect.quoteIdentifier(keyColumn)
            let value = originalRow[index]
            guard value != .null else {
                terms.append("\(quoted) IS NULL")
                continue
            }
            terms.append("\(quoted) = ?")
            parameters.append(value)
        }
        return (terms.joined(separator: " AND "), parameters)
    }

    private static func isDefaultSentinel(_ cell: SpannerCell) -> Bool {
        cell == .text(SpannerRowEditSQL.defaultSentinel)
    }

    private static func lastValuePerColumn(_ cells: [SpannerRowChange.CellChange]) -> [SpannerRowChange.CellChange] {
        var order: [String] = []
        var values: [String: SpannerCell] = [:]
        for cell in cells {
            if values.updateValue(cell.value, forKey: cell.column) == nil {
                order.append(cell.column)
            }
        }
        return order.compactMap { column in values[column].map { SpannerRowChange.CellChange(column: column, value: $0) } }
    }
}
