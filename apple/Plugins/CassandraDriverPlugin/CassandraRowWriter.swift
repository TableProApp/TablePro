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
    static let unappliedMarker = CassandraConditionalWrite.appliedColumn

    // What a browse kept for the row with these primary key values, by column name.
    typealias Lifetimes = ([String: PluginCellValue]) -> CassandraRowLifetimes?

    static func rowWrites(
        keyspace: String?,
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        lifetimes: @escaping Lifetimes = { _ in nil }
    ) throws -> [PluginRowWrite] {
        let target = CassandraBrowseRenderer.qualifiedTable(keyspace: keyspace, table: table)
        let writer = Writer(
            target: target, columns: columns, primaryKeyColumns: primaryKeyColumns, lifetimes: lifetimes
        )
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

    // Writes deleted rows back as they were, key included and each cell with the TTL it had left, to undo a delete.
    // A plain `INSERT` rather than `IF NOT EXISTS`: restoring a row means making it what it was, whatever took its
    // place since.
    static func restoreInserts(
        keyspace: String?,
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        lifetimes: Lifetimes = { _ in nil }
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        let target = CassandraBrowseRenderer.qualifiedTable(keyspace: keyspace, table: table)
        let now = ContinuousClock.now
        return rows.map { row in
            let width = min(row.count, columns.count)
            let names = Array(columns.prefix(width))
            let values = Array(row.prefix(width))
            let kept = rowKey(primaryKeyColumns, columns: names, row: values).flatMap(lifetimes)
            let keys = kept.flatMap { kept -> CassandraLifetimeWrite.RowKeys<PluginCellValue>? in
                guard let whole = condition(naming: primaryKeyColumns, columns: names, row: values),
                      let partition = condition(naming: kept.layout.partitionKey, columns: names, row: values)
                else { return nil }
                return CassandraLifetimeWrite.RowKeys(row: whole, partition: partition)
            }
            let cells = zip(names, values).map { name, value in
                CassandraLifetimeWrite.RestoredCell(
                    column: name,
                    value: value,
                    isKey: primaryKeyColumns.contains(name),
                    isNull: value.isNull,
                    isStatic: kept?.layout.staticColumns.contains(name) ?? false,
                    timeToLive: kept?.timeToLive(of: name, at: now)
                )
            }
            let write = CassandraLifetimeWrite.restore(target: target, cells: cells, keys: keys)
            return (write.cql, write.parameters)
        }
    }

    static func rowKey(
        _ keyColumns: [String],
        columns: [String],
        row: [PluginCellValue]
    ) -> [String: PluginCellValue]? {
        guard !keyColumns.isEmpty else { return nil }
        var key: [String: PluginCellValue] = [:]
        for keyColumn in keyColumns {
            guard let index = columns.firstIndex(of: keyColumn), index < row.count, !row[index].isNull else {
                return nil
            }
            key[keyColumn] = row[index]
        }
        return key
    }

    static func condition(
        naming keyColumns: [String],
        columns: [String],
        row: [PluginCellValue]
    ) -> CassandraLifetimeWrite.KeyCondition<PluginCellValue>? {
        guard let key = rowKey(keyColumns, columns: columns, row: row) else { return nil }
        return CassandraLifetimeWrite.KeyCondition(
            cql: keyColumns.map { "\(CassandraBrowseRenderer.quote($0)) = ?" }.joined(separator: " AND "),
            values: keyColumns.compactMap { key[$0] }
        )
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
        let lifetimes: Lifetimes

        func insert(_ change: PluginRowChange, values: [PluginCellValue]?) throws -> PluginRowWrite {
            guard !primaryKeyColumns.isEmpty else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                    localized: "The table's primary key is not loaded, so the row cannot be written."
                ))
            }
            let row = values ?? rowFromCellChanges(change)
            // A new row built from its edits leaves every column it never set to the server.
            let leftOut = (change.defaultColumns ?? []).union(
                values == nil ? Set(columns.indices).subtracting(change.cellChanges.map(\.columnIndex)) : []
            )
            let expressionColumns = change.expressionColumns ?? []
            var names: [String] = []
            var placeholders: [String] = []
            var parameters: [PluginCellValue] = []
            for (index, value) in row.enumerated() where index < columns.count {
                if leftOut.contains(index) { continue }
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
                      !leftOut.contains(index)
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
            let kept = change.originalRow
                .flatMap { CassandraRowWriter.rowKey(primaryKeyColumns, columns: columns, row: $0) }
                .flatMap(lifetimes)
            let now = ContinuousClock.now
            var assignments: [CassandraLifetimeWrite.Assignment<PluginCellValue>] = []
            for cell in change.cellChanges {
                if primaryKeyColumns.contains(cell.columnName) {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        format: String(
                            localized: "Cassandra cannot change the primary key column %@. Delete the row and add it again with the new key."
                        ),
                        cell.columnName
                    ))
                }
                if change.isColumnDefault(cell.columnIndex) {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        localized: "Cassandra columns have no default value."
                    ))
                }
                if kept?.hasExpired(cell.columnName, at: now) == true {
                    throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                        format: String(
                            localized: "The value in %@ expired after the grid read it. Refresh, then edit the row again."
                        ),
                        cell.columnName
                    ))
                }
                let column = CassandraBrowseRenderer.quote(cell.columnName)
                let call = expression(cell.newValue, isMarked: expressionColumns.contains(cell.columnIndex))
                assignments.append(CassandraLifetimeWrite.Assignment(
                    cql: "\(column) = \(call ?? "?")",
                    parameters: call == nil ? [cell.newValue] : [],
                    timeToLive: kept?.timeToLive(of: cell.columnName, at: now),
                    isStatic: kept?.layout.staticColumns.contains(cell.columnName) ?? false
                ))
            }
            let key = try keyCondition(for: change)
            let partition = change.originalRow.flatMap { original in
                kept.flatMap { CassandraRowWriter.condition(naming: $0.layout.partitionKey, columns: columns, row: original) }
            }
            let write = CassandraLifetimeWrite.update(
                target: target, assignments: assignments, row: key, partition: partition
            )
            return PluginRowWrite(statement: write.cql, parameters: write.parameters, rowIndices: [change.rowIndex])
        }

        func delete(_ change: PluginRowChange) throws -> PluginRowWrite {
            let key = try keyCondition(for: change)
            return PluginRowWrite(
                statement: "DELETE FROM \(target) WHERE \(key.cql)", parameters: key.values, rowIndices: [change.rowIndex]
            )
        }

        private func keyCondition(for change: PluginRowChange) throws -> CassandraLifetimeWrite.KeyCondition<PluginCellValue> {
            guard let original = change.originalRow,
                  let key = CassandraRowWriter.condition(naming: primaryKeyColumns, columns: columns, row: original)
            else {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: String(
                    localized: "The row's primary key is not loaded, so the row cannot be found."
                ))
            }
            return key
        }

        private func rowFromCellChanges(_ change: PluginRowChange) -> [PluginCellValue] {
            var row = [PluginCellValue](repeating: .null, count: columns.count)
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
