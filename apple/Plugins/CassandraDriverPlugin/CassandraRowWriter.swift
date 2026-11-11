//
//  CassandraRowWriter.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProCassandraCore
import TableProPluginKit

// One statement per row, each naming the row by its whole primary key: CQL has no `OR` and no parenthesised groups.
// A new row is written `IF NOT EXISTS` and an edit `IF EXISTS` (CassandraConditionalWrite), and anything CQL cannot
// do to a row is refused by name rather than sent.
enum CassandraRowWriter {
    static let defaultSentinel = "__DEFAULT__"
    static let unappliedMarker = CassandraConditionalWrite.appliedColumn

    static func rowWrites(
        keyspace: String?,
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> [PluginRowWrite] {
        let target = CassandraBrowseRenderer.qualifiedTable(keyspace: keyspace, table: table)
        let writer = Writer(target: target, columns: columns, primaryKeyColumns: primaryKeyColumns)
        return try changes.compactMap { change in
            switch change.type {
            case .insert:
                return try writer.insert(change, values: insertedRowData[change.rowIndex])
            case .update:
                return try writer.update(change)
            case .delete:
                return try writer.delete(change)
            }
        }
    }

    /// Writes deleted rows back as they were, key included, to undo a delete. A plain `INSERT` rather than
    /// `IF NOT EXISTS`: restoring a row means making it what it was, whatever took its place since.
    static func restoreInserts(
        keyspace: String?,
        table: String,
        columns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        let target = CassandraBrowseRenderer.qualifiedTable(keyspace: keyspace, table: table)
        return rows.map { row in
            let width = min(row.count, columns.count)
            let names = columns.prefix(width).map(CassandraBrowseRenderer.quote).joined(separator: ", ")
            let markers = Array(repeating: "?", count: width).joined(separator: ", ")
            return ("INSERT INTO \(target) (\(names)) VALUES (\(markers))", Array(row.prefix(width)))
        }
    }

    static func unappliedWriteRefusal(statement: String, columns: [String], rows: [[PluginCellValue]]) -> String? {
        let refusal = CassandraConditionalWrite.refusal(
            statement: statement, firstColumn: columns.first, firstValue: rows.first?.first?.asText
        )
        switch refusal {
        case .keyTaken:
            return String(localized: "A row with this primary key already exists. Edit that row instead.")
        case .rowMissing:
            return String(localized: "No row has this primary key, so nothing was updated. Another client may have deleted it.")
        case nil:
            return nil
        }
    }

    private struct Writer {
        let target: String
        let columns: [String]
        let primaryKeyColumns: [String]

        func insert(_ change: PluginRowChange, values: [PluginCellValue]?) throws -> PluginRowWrite {
            guard !primaryKeyColumns.isEmpty else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                    localized: "The table's primary key is not loaded, so the row cannot be written."
                ))
            }
            let row = values ?? rowFromCellChanges(change)
            let expressionColumns = change.expressionColumns ?? []
            var names: [String] = []
            var placeholders: [String] = []
            var parameters: [PluginCellValue] = []
            for (index, value) in row.enumerated() where index < columns.count {
                if value.asText == defaultSentinel { continue }
                names.append(CassandraBrowseRenderer.quote(columns[index]))
                if let call = expression(value, isMarked: expressionColumns.contains(index)) {
                    placeholders.append(call)
                } else {
                    placeholders.append("?")
                    parameters.append(value)
                }
            }
            for keyColumn in primaryKeyColumns {
                guard let index = columns.firstIndex(of: keyColumn), index < row.count, !row[index].isNull,
                      row[index].asText != defaultSentinel
                else {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        format: String(localized: "Enter a value for the primary key column %@."), keyColumn
                    ))
                }
            }
            let statement = CassandraConditionalWrite.insertStatement(target: target, names: names, values: placeholders)
            return PluginRowWrite(statement: statement, parameters: parameters, rowIndices: [change.rowIndex])
        }

        func update(_ change: PluginRowChange) throws -> PluginRowWrite? {
            guard !change.cellChanges.isEmpty else { return nil }
            let expressionColumns = change.expressionColumns ?? []
            var assignments: [String] = []
            var parameters: [PluginCellValue] = []
            for cell in change.cellChanges {
                if primaryKeyColumns.contains(cell.columnName) {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        format: String(
                            localized: "Cassandra cannot change the primary key column %@. Delete the row and add it again with the new key."
                        ),
                        cell.columnName
                    ))
                }
                if cell.newValue.asText == defaultSentinel {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        localized: "Cassandra columns have no default value."
                    ))
                }
                let column = CassandraBrowseRenderer.quote(cell.columnName)
                if let call = expression(cell.newValue, isMarked: expressionColumns.contains(cell.columnIndex)) {
                    assignments.append("\(column) = \(call)")
                } else {
                    assignments.append("\(column) = ?")
                    parameters.append(cell.newValue)
                }
            }
            let key = try keyCondition(for: change)
            let statement = CassandraConditionalWrite.updateStatement(
                target: target, assignments: assignments, keyCondition: key.cql
            )
            return PluginRowWrite(statement: statement, parameters: parameters + key.values, rowIndices: [change.rowIndex])
        }

        func delete(_ change: PluginRowChange) throws -> PluginRowWrite {
            let key = try keyCondition(for: change)
            return PluginRowWrite(
                statement: "DELETE FROM \(target) WHERE \(key.cql)", parameters: key.values, rowIndices: [change.rowIndex]
            )
        }

        private func keyCondition(for change: PluginRowChange) throws -> (cql: String, values: [PluginCellValue]) {
            guard !primaryKeyColumns.isEmpty, let original = change.originalRow else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                    localized: "The row's primary key is not loaded, so the row cannot be found."
                ))
            }
            var conditions: [String] = []
            var values: [PluginCellValue] = []
            for keyColumn in primaryKeyColumns {
                guard let index = columns.firstIndex(of: keyColumn), index < original.count, !original[index].isNull else {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        localized: "The row's primary key is not loaded, so the row cannot be found."
                    ))
                }
                conditions.append("\(CassandraBrowseRenderer.quote(keyColumn)) = ?")
                values.append(original[index])
            }
            return (conditions.joined(separator: " AND "), values)
        }

        private func rowFromCellChanges(_ change: PluginRowChange) -> [PluginCellValue] {
            var row = [PluginCellValue](repeating: .text(defaultSentinel), count: columns.count)
            for cell in change.cellChanges where cell.columnIndex < row.count {
                row[cell.columnIndex] = cell.newValue
            }
            return row
        }

        // The host checked a marked cell's text against the engine's vocabulary before handing it over.
        private func expression(_ value: PluginCellValue, isMarked: Bool) -> String? {
            guard isMarked, case .text(let cql) = value else { return nil }
            return cql
        }
    }
}
