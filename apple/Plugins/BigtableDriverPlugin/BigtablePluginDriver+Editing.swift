import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
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
        try changes.compactMap { change in
            do {
                return try request(
                    for: change, table: table, columns: columns, insertedRowData: insertedRowData,
                    locator: context.rowLocators[change.rowIndex]
                ).map { PluginRowWrite(statement: $0.text, rowIndices: [change.rowIndex]) }
            } catch {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: error.localizedDescription)
            }
        }
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateIdentityPreservingInsert(
            table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns, rows: rows,
            absentCells: absentCells, context: PluginRowWriteContext()
        )
    }

    // Restoring a deleted row writes it back under its own key, refused if that key is taken again.
    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>],
        context: PluginRowWriteContext
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let keyIndex = columns.firstIndex(of: BigtableRowSet.keyColumn)
        let statements = rows.enumerated().compactMap { index, row -> String? in
            var values = cells(row, absent: absentCells[index] ?? [])
            if let keyIndex, keyIndex < values.count {
                guard let key = try? BigtableRowWrites.originalKey(locator: context.rowLocators[index], keyCell: values[keyIndex]) else {
                    return nil
                }
                values[keyIndex] = .bytes(key)
            }
            return try? BigtableRowWrites.insert(table: table, columns: columns, values: values).text
        }
        return statements.count == rows.count ? statements.map { ($0, []) } : nil
    }

    private func request(
        for change: PluginRowChange,
        table: String,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        locator: String?
    ) throws -> BigtableRequest? {
        let absent = change.absentColumns ?? []
        switch change.type {
        case .insert:
            return try BigtableRowWrites.insert(
                table: table,
                columns: columns,
                values: cells(insertedRowData[change.rowIndex] ?? [], absent: absent.union(change.defaultColumns ?? []))
            )
        case .update:
            let changes = try change.cellChanges.map { cell in
                guard !change.isColumnDefault(cell.columnIndex) else {
                    throw BigtableError.unsupported(String(localized: "Bigtable has no default values. Delete the cell, or enter a value."))
                }
                return (column: cell.columnName, value: absent.contains(cell.columnIndex) ? BigtableRowSet.Cell.absent : Self.cell(cell.newValue))
            }
            return try BigtableRowWrites.update(
                table: table, key: try originalKey(change, columns: columns, locator: locator), changes: changes
            )
        case .delete:
            return BigtableRowWrites.delete(table: table, key: try originalKey(change, columns: columns, locator: locator))
        }
    }

    private func originalKey(_ change: PluginRowChange, columns: [String], locator: String?) throws -> Data {
        var keyCell: BigtableRowSet.Cell?
        if let index = columns.firstIndex(of: BigtableRowSet.keyColumn), let row = change.originalRow, index < row.count {
            keyCell = Self.cell(row[index])
        }
        guard let key = try BigtableRowWrites.originalKey(locator: locator, keyCell: keyCell) else {
            throw BigtableError.configuration(String(localized: "The row has no _key, so the row it came from is unknown. Reload the table."))
        }
        return key
    }

    // Bigtable generates nothing, so a cell left to the default is left out, and a `_key` left that way is refused.
    private func cells(_ row: [PluginCellValue], absent: Set<Int>) -> [BigtableRowSet.Cell] {
        row.enumerated().map { index, value in
            absent.contains(index) ? .absent : Self.cell(value)
        }
    }

    private static func cell(_ value: PluginCellValue) -> BigtableRowSet.Cell {
        switch value {
        case .null: return .absent
        case .text(let text): return .text(text)
        case .bytes(let data): return .bytes(data)
        }
    }
}
