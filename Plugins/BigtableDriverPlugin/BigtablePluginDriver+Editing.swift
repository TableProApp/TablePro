import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
    private static let defaultMarker = "__DEFAULT__"

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
        try changes.compactMap { change in
            do {
                return try request(for: change, table: table, columns: columns, insertedRowData: insertedRowData)
                    .map { PluginRowWrite(statement: $0.text, rowIndices: [change.rowIndex]) }
            } catch {
                throw PluginRowWriteRefusal(rowIndex: change.rowIndex, reason: error.localizedDescription)
            }
        }
    }

    /// Restoring a deleted row writes it back under its own key, refused if that key is taken again.
    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let statements = rows.enumerated().compactMap { index, row in
            try? BigtableRowWrites.insert(table: table, columns: columns, values: cells(row, absent: absentCells[index] ?? [])).text
        }
        return statements.count == rows.count ? statements.map { ($0, []) } : nil
    }

    private func request(
        for change: PluginRowChange,
        table: String,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> BigtableRequest? {
        let absent = change.absentColumns ?? []
        switch change.type {
        case .insert:
            return try BigtableRowWrites.insert(
                table: table, columns: columns, values: cells(insertedRowData[change.rowIndex] ?? [], absent: absent)
            )
        case .update:
            let changes = try change.cellChanges.map { cell in
                guard cell.newValue.asText != Self.defaultMarker else {
                    throw BigtableError.unsupported(String(localized: "Bigtable has no default values. Delete the cell, or enter a value."))
                }
                return (column: cell.columnName, value: absent.contains(cell.columnIndex) ? BigtableRowSet.Cell.absent : Self.cell(cell.newValue))
            }
            return try BigtableRowWrites.update(table: table, key: try originalKey(change, columns: columns), changes: changes)
        case .delete:
            return BigtableRowWrites.delete(table: table, key: try originalKey(change, columns: columns))
        }
    }

    private func originalKey(_ change: PluginRowChange, columns: [String]) throws -> Data {
        guard let index = columns.firstIndex(of: BigtableRowSet.keyColumn),
              let row = change.originalRow, index < row.count,
              let key = try BigtableRowWrites.key(Self.cell(row[index])) else {
            throw BigtableError.configuration(String(localized: "The row has no _key, so the row it came from is unknown. Reload the table."))
        }
        return key
    }

    /// A new row holds the host's Default marker where it has no value yet. Bigtable generates
    /// nothing, so that cell is left out, and a `_key` left that way is refused.
    private func cells(_ row: [PluginCellValue], absent: Set<Int>) -> [BigtableRowSet.Cell] {
        row.enumerated().map { index, value in
            absent.contains(index) || value.asText == Self.defaultMarker ? .absent : Self.cell(value)
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
