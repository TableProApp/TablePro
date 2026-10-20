import Foundation
import TableProModels

nonisolated struct ForeignKeyReference: Hashable, Identifiable, Sendable {
    nonisolated struct Part: Hashable, Sendable {
        let column: String
        let value: String
    }

    let table: String
    let schema: String?
    let parts: [Part]

    var id: Self { self }

    static func make(
        forColumn column: String,
        foreignKeys: [ForeignKeyInfo],
        columns: [ColumnInfo],
        cells: [Cell],
        sourceSchema: String?
    ) -> Self? {
        guard let target = columnIndex(named: column, in: columns) else { return nil }
        for key in keys(in: foreignKeys) where key.contains(where: { columnIndex(named: $0.column, in: columns) == target }) {
            if let reference = resolve(key, columns: columns, cells: cells, sourceSchema: sourceSchema) {
                return reference
            }
        }
        return nil
    }

    static func all(
        foreignKeys: [ForeignKeyInfo],
        columns: [ColumnInfo],
        cells: [Cell],
        sourceSchema: String?
    ) -> [(name: String, column: String, reference: Self)] {
        keys(in: foreignKeys).compactMap { key in
            guard let first = key.first,
                  let reference = resolve(key, columns: columns, cells: cells, sourceSchema: sourceSchema)
            else { return nil }
            return (name: first.name, column: key.map(\.column).joined(separator: ", "), reference: reference)
        }
    }

    func displaySchema(current: String?) -> String? {
        guard let schema, schema != current else { return nil }
        return schema
    }

    // A key can only point at a base table, and a table outside the active schema is not in the catalog.
    func catalogTable(in tables: [TableInfo], currentSchema: String?) -> TableInfo {
        let fallback = TableInfo(name: table, type: .table)
        guard displaySchema(current: currentSchema) == nil else { return fallback }
        if let exact = tables.first(where: { $0.name == table }) { return exact }
        let folded = tables.filter { $0.name.caseInsensitiveCompare(table) == .orderedSame }
        return folded.count == 1 ? folded[0] : fallback
    }

    // The browser drops an invalid filter, so a blank value would open the whole table.
    func filters() -> [TableFilter]? {
        let filters = parts.map { TableFilter(columnName: $0.column, filterOperator: .equal, value: $0.value) }
        guard !filters.isEmpty, filters.allSatisfy(\.isValid) else { return nil }
        return filters
    }

    private static func keys(in foreignKeys: [ForeignKeyInfo]) -> [[ForeignKeyInfo]] {
        var groups: [[ForeignKeyInfo]] = []
        for foreignKey in foreignKeys {
            if let index = groups.firstIndex(where: { sameKey($0[0], foreignKey) }) {
                groups[index].append(foreignKey)
            } else {
                groups.append([foreignKey])
            }
        }
        return groups
    }

    private static func sameKey(_ lhs: ForeignKeyInfo, _ rhs: ForeignKeyInfo) -> Bool {
        lhs.name == rhs.name && lhs.referencedTable == rhs.referencedTable && lhs.referencedSchema == rhs.referencedSchema
    }

    // Only a `.text` cell holds the value itself; a binary or truncated cell holds a placeholder.
    private static func resolve(
        _ key: [ForeignKeyInfo],
        columns: [ColumnInfo],
        cells: [Cell],
        sourceSchema: String?
    ) -> Self? {
        guard let first = key.first else { return nil }
        var parts: [Part] = []
        for pair in key {
            guard let index = columnIndex(named: pair.column, in: columns), index < cells.count,
                  case .text(let value) = cells[index]
            else { return nil }
            parts.append(Part(column: pair.referencedColumn, value: value))
        }
        return Self(table: first.referencedTable, schema: first.referencedSchema ?? sourceSchema, parts: parts)
    }

    private static func columnIndex(named name: String, in columns: [ColumnInfo]) -> Int? {
        if let exact = columns.firstIndex(where: { $0.name == name }) { return exact }
        let folded = columns.indices.filter { columns[$0].name.caseInsensitiveCompare(name) == .orderedSame }
        return folded.count == 1 ? folded[0] : nil
    }
}
