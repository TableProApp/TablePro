import Foundation
import TableProPluginKit
import TableProTrinoCore

extension TrinoPluginDriver {
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try generateRowWrites(
            table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns, changes: changes,
            insertedRowData: insertedRowData, deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices, context: PluginRowWriteContext()
        )
    }

    // Trino enforces no key and a connector runs each statement on its own, so every update and delete first has to
    // find exactly one row. The types come from the host, which read them on whichever connection loaded the table.
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        let target = qualifiedName(table: table, schema: schema)
        let typeName = columnTypeName(table: table, schema: schema, context: context)

        var writes: [PluginRowWrite] = []
        for change in changes {
            let expressions = Set((change.expressionColumns ?? []).compactMap {
                columns.indices.contains($0) ? columns[$0] : nil
            })
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                let values = TrinoRowEditValues.insertValues(
                    change, columns: columns, insertedRowData: insertedRowData, typeName: typeName
                ).map { TrinoRowEditValues.writing($0, asExpression: expressions.contains($0.name)) }
                if let sql = TrinoRowEditSQL.insert(qualifiedTable: target, columns: values) {
                    writes.append(PluginRowWrite(statement: sql, rowIndices: [change.rowIndex]))
                }
            case .update:
                guard !change.cellChanges.isEmpty else { continue }
                let assignments = change.cellChanges.map {
                    TrinoRowEditValues.writing(
                        TrinoColumnValue(
                            name: $0.columnName,
                            value: TrinoRowEditValues.trinoValue($0.newValue),
                            typeName: typeName($0.columnName)
                        ),
                        asExpression: expressions.contains($0.columnName)
                    )
                }
                let keys = try keyColumns(primaryKeyColumns, columns: columns, change: change, typeName: typeName)
                guard let sql = TrinoRowEditSQL.update(qualifiedTable: target, assignments: assignments, keyColumns: keys)
                else { throw Self.unmatchable(change) }
                writes.append(PluginRowWrite(statement: sql, rowIndices: [change.rowIndex], lookup: lookup(target, keys)))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                let keys = try keyColumns(primaryKeyColumns, columns: columns, change: change, typeName: typeName)
                guard let sql = TrinoRowEditSQL.delete(qualifiedTable: target, keyColumns: keys) else {
                    throw Self.unmatchable(change)
                }
                writes.append(PluginRowWrite(statement: sql, rowIndices: [change.rowIndex], lookup: lookup(target, keys)))
            }
        }
        return writes
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let target = qualifiedName(table: table, schema: schema)
        let typeName = columnTypeName(table: table, schema: schema, context: nil)
        return rows.compactMap { row in
            let values = zip(columns, row).map {
                TrinoColumnValue(name: $0, value: TrinoRowEditValues.trinoValue($1), typeName: typeName($0))
            }
            return TrinoRowEditSQL.insert(qualifiedTable: target, columns: values).map { ($0, []) }
        }
    }

    private func columnTypeName(
        table: String,
        schema: String?,
        context: PluginRowWriteContext?
    ) -> (String) -> String {
        let cached = cachedColumnTypes(key: columnTypeKey(schema: schema, table: table))
        let read = context?.columnTypeNames ?? [:]
        return { read[$0] ?? cached[$0] ?? "varchar" }
    }

    private func lookup(_ target: String, _ keys: [TrinoColumnValue]) -> PluginRowLookup? {
        TrinoRowEditSQL.lookup(qualifiedTable: target, keyColumns: keys).map {
            PluginRowLookup(query: $0, parameters: [], rowCount: 1, pinsRows: false)
        }
    }

    private static func unmatchable(_ change: PluginRowChange) -> PluginRowWriteRefusal {
        PluginRowWriteRefusal(
            rowIndex: change.rowIndex,
            reason: String(localized: "The row's loaded values are missing, so it cannot be found again.")
        )
    }

    private func keyColumns(
        _ primaryKeyColumns: [String],
        columns: [String],
        change: PluginRowChange,
        typeName: (String) -> String
    ) throws -> [TrinoColumnValue] {
        let keyNames = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        var keys: [TrinoColumnValue] = []
        for column in keyNames {
            // Leaving a column out of the match reaches every row that shares the rest.
            guard let value = originalValue(column, columns: columns, change: change) else { throw Self.unmatchable(change) }
            keys.append(TrinoColumnValue(name: column, value: TrinoRowEditValues.trinoValue(value), typeName: typeName(column)))
        }
        return keys
    }

    private func originalValue(_ column: String, columns: [String], change: PluginRowChange) -> PluginCellValue? {
        if let originalRow = change.originalRow, let index = columns.firstIndex(of: column), index < originalRow.count {
            return originalRow[index]
        }
        return change.cellChanges.first { $0.columnName == column }?.oldValue
    }
}
