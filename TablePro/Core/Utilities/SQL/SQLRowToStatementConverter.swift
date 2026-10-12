//
//  SQLRowToStatementConverter.swift
//  TablePro

import Foundation
import TableProPluginKit

/// Writes grid rows as INSERT and UPDATE text for the user to run, with the values written in.
///
/// The statements follow the rules the grid's own save does: a column the server owns is never assigned, every key
/// column identifies the row, a row with no key is matched on every column it has through the same row-match policy,
/// and the WHERE clause names the row as it is stored, not as it has been edited.
internal struct SQLRowToStatementConverter {
    /// One row of the grid, as it is shown and as the server has it.
    ///
    /// `defaultedColumns` names the cells the grid staged as left to the server's default. The grid spells that as the
    /// text `__DEFAULT__`, which a stored value can also be, so only a cell named here is read as the marker.
    internal struct SourceRow {
        internal let values: [PluginCellValue]
        internal let storedValues: [PluginCellValue]
        internal let isPendingInsert: Bool
        internal let defaultedColumns: Set<Int>

        internal init(
            values: [PluginCellValue],
            storedValues: [PluginCellValue]? = nil,
            isPendingInsert: Bool = false,
            defaultedColumns: Set<Int> = []
        ) {
            self.values = values
            self.storedValues = storedValues ?? values
            self.isPendingInsert = isPendingInsert
            self.defaultedColumns = defaultedColumns
        }
    }

    internal let tableName: String
    internal let columns: [String]
    internal let primaryKeyColumns: [String]
    internal let databaseType: DatabaseType
    private let schemaName: String?
    private let unwritableColumns: Set<String>
    private let rowMatchPolicy: RowMatchPolicy
    private let settableColumns: [String]?
    private let quoteIdentifierFn: (String) -> String
    private let escapeStringFn: (String) -> String

    private static let maxRows = 50_000

    init(
        tableName: String,
        schemaName: String? = nil,
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType,
        unwritableColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        settableColumns: [String]? = nil,
        dialect: SQLDialectDescriptor? = nil,
        quoteIdentifier: ((String) -> String)? = nil,
        escapeStringLiteral: ((String) -> String)? = nil
    ) throws {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.databaseType = databaseType
        self.unwritableColumns = unwritableColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.settableColumns = settableColumns

        if let quoteIdentifier, let escapeStringLiteral {
            self.quoteIdentifierFn = quoteIdentifier
            self.escapeStringFn = escapeStringLiteral
            return
        }

        let resolvedDialect = try resolveSQLDialect(for: databaseType, explicit: dialect)
        self.quoteIdentifierFn = quoteIdentifier ?? quoteIdentifierFromDialect(resolvedDialect)
        self.escapeStringFn = escapeStringLiteral ?? escapeStringLiteralFromDialect(resolvedDialect)
    }

    private var qualifiedTable: String {
        SchemaQualifiedName.render(name: tableName, schema: schemaName, databaseType: databaseType, quote: quoteIdentifierFn)
    }

    // MARK: - INSERT

    internal func generateInserts(rows: [SourceRow]) -> String {
        rows.prefix(Self.maxRows).compactMap(insertStatement).joined(separator: "\n")
    }

    /// A column the server owns, or one the row leaves to its default, stays out of the list, so the copied statement
    /// inserts what a save of the same row would.
    private func insertStatement(row: SourceRow) -> String? {
        let written = zip(columns.indices, zip(columns, row.values)).filter { index, cell in
            !unwritableColumns.contains(cell.0) && !row.defaultedColumns.contains(index)
        }.map(\.1)
        guard !written.isEmpty else {
            let firstWritable = columns.first { !unwritableColumns.contains($0) }.map(quoteIdentifierFn)
            return AllDefaultsInsert.sql(
                into: qualifiedTable, databaseType: databaseType, firstWritableColumn: firstWritable
            ).map { "\($0);" }
        }
        let columnList = written.map { quoteIdentifierFn($0.0) }.joined(separator: ", ")
        let values = written.map { formatValue($0.1) }.joined(separator: ", ")
        return "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES (\(values));"
    }

    // MARK: - UPDATE

    internal func generateUpdates(rows: [SourceRow]) -> String {
        rows.prefix(Self.maxRows).compactMap(updateStatement).joined(separator: "\n")
    }

    /// Nothing for a row the table does not hold yet, for a key that is NULL (which identifies no row), for a row with
    /// nothing left to assign, and for a table without a key that has a column no match can compare: leaving that
    /// column out would let the statement change rows that differ only in it.
    private func updateStatement(row: SourceRow) -> String? {
        guard !row.isPendingInsert, let whereClause = rowMatch(storedValues: row.storedValues) else { return nil }
        let assignments = assignments(for: row)
        guard !assignments.isEmpty else { return nil }
        return "UPDATE \(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause);"
    }

    private var keyColumnsPresent: Bool {
        !primaryKeyColumns.isEmpty && primaryKeyColumns.allSatisfy(columns.contains)
    }

    /// A key column is assigned only when its value was edited, so a changed natural key is carried and an unchanged
    /// one is not restated.
    private func assignments(for row: SourceRow) -> [String] {
        let keys = keyColumnsPresent ? Set(primaryKeyColumns) : []
        return (settableColumns ?? columns).compactMap { column -> String? in
            guard !unwritableColumns.contains(column), let index = columns.firstIndex(of: column) else { return nil }
            let value = row.values.indices.contains(index) ? row.values[index] : .null
            if keys.contains(column) {
                let stored = row.storedValues.indices.contains(index) ? row.storedValues[index] : .null
                guard value != stored else { return nil }
            }
            guard !row.defaultedColumns.contains(index) else { return "\(quoteIdentifierFn(column)) = DEFAULT" }
            return "\(quoteIdentifierFn(column)) = \(formatValue(value))"
        }
    }

    private func rowMatch(storedValues: [PluginCellValue]) -> String? {
        guard primaryKeyColumns.isEmpty || keyColumnsPresent else { return nil }
        if keyColumnsPresent {
            let conditions = primaryKeyColumns.compactMap { key -> String? in
                guard let index = columns.firstIndex(of: key), storedValues.indices.contains(index),
                      !storedValues[index].isNull else { return nil }
                return "\(quoteIdentifierFn(key)) = \(formatValue(storedValues[index]))"
            }
            return conditions.count == primaryKeyColumns.count ? conditions.joined(separator: " AND ") : nil
        }

        guard columns.allSatisfy({ !rowMatchPolicy.excludedColumns.contains($0) }) else { return nil }
        let conditions = columns.enumerated().map { index, column -> String in
            let value = storedValues.indices.contains(index) ? storedValues[index] : .null
            let compared = rowMatchPolicy.matchExpression(
                for: column, quoted: quoteIdentifierFn(column), value: value, databaseType: databaseType
            )
            return value.isNull ? "\(compared) IS NULL" : "\(compared) = \(formatValue(value))"
        }
        return conditions.isEmpty ? nil : conditions.joined(separator: " AND ")
    }

    // MARK: - Literals

    private func formatValue(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let s):
            return "\(SQLStringLiteralPrefix.forDatabaseType(databaseType))'\(escapeStringFn(s))'"
        case .bytes(let data):
            return formatBinaryLiteral(data)
        }
    }

    private func formatBinaryLiteral(_ data: Data) -> String {
        var hex = ""
        hex.reserveCapacity(data.count * 2)
        for byte in data {
            hex += String(format: "%02X", byte)
        }
        switch databaseType {
        case .postgresql, .redshift, .cockroachdb:
            return "'\\x\(hex)'::bytea"
        case .mssql:
            return "0x\(hex)"
        default:
            return "X'\(hex)'"
        }
    }
}
