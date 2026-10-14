import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
    /// Each change becomes one request line, the text the editor takes, so the history shows what
    /// was sent. All cells of a row change in one atomic `mutateRow`.
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
                    .map { PluginRowWrite(statement: $0.text(defaultTable: table), rowIndices: [change.rowIndex]) }
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
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let statements = rows.enumerated().compactMap { index, row -> String? in
            let change = PluginRowChange(rowIndex: index, type: .insert, cellChanges: [], originalRow: nil)
            return (try? request(for: change, table: table, columns: columns, insertedRowData: [index: row]))??.text(defaultTable: table)
        }
        return statements.count == rows.count ? statements.map { ($0, []) } : nil
    }

    private func request(
        for change: PluginRowChange,
        table: String,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]]
    ) throws -> BigtableRequest? {
        let keyColumn = BigtableRowSet.keyColumn
        switch change.type {
        case .insert:
            let row = insertedRowData[change.rowIndex] ?? []
            let absent = change.absentColumns ?? []
            var cells: [String: Any] = [:]
            var key: Data?
            for (index, column) in columns.enumerated() where index < row.count && !absent.contains(index) {
                if column == keyColumn {
                    key = try keyBytes(row[index])
                    continue
                }
                guard let value = Self.text(row[index]) else { continue }
                cells[column] = value
            }
            guard let key, !key.isEmpty else {
                throw BigtableError.configuration(String(localized: "A new row needs a _key. Bigtable has no generated keys."))
            }
            guard !cells.isEmpty else {
                throw BigtableError.configuration(String(localized: "A new row needs at least one cell. Bigtable does not store empty rows."))
            }
            return BigtableRequest(verb: .put, key: key, body: try Self.body(cells))
        case .update:
            let key = try originalKey(change, columns: columns)
            let absent = change.absentColumns ?? []
            var cells: [String: Any] = [:]
            for cell in change.cellChanges where cell.columnName != keyColumn {
                cells[cell.columnName] = absent.contains(cell.columnIndex) ? NSNull() : (Self.text(cell.newValue) ?? NSNull())
            }
            for index in absent where index < columns.count && columns[index] != keyColumn && cells[columns[index]] == nil {
                cells[columns[index]] = NSNull()
            }
            guard !cells.isEmpty else { return nil }
            return BigtableRequest(verb: .put, key: key, body: try Self.body(cells))
        case .delete:
            return BigtableRequest(verb: .delete, key: try originalKey(change, columns: columns))
        }
    }

    private func originalKey(_ change: PluginRowChange, columns: [String]) throws -> Data {
        guard let index = columns.firstIndex(of: BigtableRowSet.keyColumn),
              let row = change.originalRow, index < row.count, let key = try keyBytes(row[index]), !key.isEmpty else {
            throw BigtableError.configuration(String(localized: "The row has no _key, so the row it came from is unknown. Reload the table."))
        }
        return key
    }

    private func keyBytes(_ cell: PluginCellValue) throws -> Data? {
        switch cell {
        case .null: return nil
        case .bytes(let data): return data
        case .text(let text): return text.isEmpty ? nil : try BigtableBytes.parse(text)
        }
    }

    /// Bytes go back as `b64:` text so a binary value survives the JSON body unchanged.
    private static func text(_ cell: PluginCellValue) -> String? {
        switch cell {
        case .null: return nil
        case .text(let text): return text
        case .bytes(let data): return BigtableBytes.base64Prefix + data.base64EncodedString()
        }
    }

    private static func body(_ cells: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: cells, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
