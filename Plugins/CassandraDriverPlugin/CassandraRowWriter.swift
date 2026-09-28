//
//  CassandraRowWriter.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

/// The CQL a grid save writes: one statement per row, each naming the row by its whole primary key.
///
/// CQL has no `OR` and no parenthesised groups, so several rows cannot share one `DELETE`, and an `INSERT` is an
/// upsert, so a new row whose key is taken would silently replace the row already there. A new row is therefore
/// written `IF NOT EXISTS`, and anything CQL cannot do to a row is refused by name rather than sent.
enum CassandraRowWriter {
    static let defaultSentinel = "__DEFAULT__"
    static let unappliedMarker = "[applied]"

    private static let functionCalls: Set<String> = [
        "now()", "uuid()", "currenttimestamp()", "currentdate()", "currenttime()", "currenttimeuuid()",
        "totimestamp(now())", "todate(now())"
    ]

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

    /// An `INSERT … IF NOT EXISTS` that found its key taken answers with `[applied] = false` and the row already
    /// there, which the server reports as a success.
    static func unappliedInsertRefusal(statement: String, columns: [String], rows: [[PluginCellValue]]) -> String? {
        let normalized = statement.uppercased()
        guard normalized.hasPrefix("INSERT"), normalized.hasSuffix("IF NOT EXISTS"),
              columns.first == unappliedMarker,
              rows.first?.first?.asText?.lowercased() == "false"
        else { return nil }
        return String(localized: "A row with this primary key already exists. Edit that row instead.")
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
            var names: [String] = []
            var placeholders: [String] = []
            var parameters: [PluginCellValue] = []
            for (index, value) in row.enumerated() where index < columns.count {
                if value.asText == defaultSentinel { continue }
                names.append(CassandraBrowseRenderer.quote(columns[index]))
                if let call = functionCall(value) {
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
            let statement = "INSERT INTO \(target) (\(names.joined(separator: ", "))) "
                + "VALUES (\(placeholders.joined(separator: ", "))) IF NOT EXISTS"
            return PluginRowWrite(statement: statement, parameters: parameters, rowIndices: [change.rowIndex])
        }

        func update(_ change: PluginRowChange) throws -> PluginRowWrite? {
            guard !change.cellChanges.isEmpty else { return nil }
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
                if let call = functionCall(cell.newValue) {
                    assignments.append("\(column) = \(call)")
                } else {
                    assignments.append("\(column) = ?")
                    parameters.append(cell.newValue)
                }
            }
            let key = try keyCondition(for: change)
            let statement = "UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(key.cql)"
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

        private func functionCall(_ value: PluginCellValue) -> String? {
            guard let text = value.asText?.trimmingCharacters(in: .whitespaces) else { return nil }
            let lowered = text.lowercased()
            return functionCalls.contains(lowered) ? lowered : nil
        }
    }
}
