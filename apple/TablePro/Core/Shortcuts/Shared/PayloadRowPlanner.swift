import Foundation

nonisolated struct PayloadColumn: Equatable, Sendable {
    let name: String
    let isPrimaryKey: Bool
    let isServerOwned: Bool
}

nonisolated enum PayloadRowPlanner {
    // The defaults suit a Shortcuts payload, which cannot say "leave this column out" except by leaving it empty.
    static func values(
        table: String,
        columns: [PayloadColumn],
        rows: [PayloadRow],
        allowAllDefaults: Bool = false,
        dropsEmptyPrimaryKey: Bool = true
    ) throws -> [[(column: String, value: String?)]] {
        guard !columns.isEmpty else { throw IntentDataError.noColumns(table) }
        let columnNames = Set(columns.map(\.name))
        let primaryKeys = Set(columns.filter(\.isPrimaryKey).map(\.name))

        return try rows.compactMap { row in
            let unknown = row.keys.filter { !columnNames.contains($0) }
            guard unknown.isEmpty else { throw IntentDataError.unknownColumns(unknown.sorted(), table) }

            var values: [(column: String, value: String?)] = []
            for column in columns {
                guard !column.isServerOwned else { continue }
                guard let value = row.value(for: column.name) else { continue }
                if dropsEmptyPrimaryKey, primaryKeys.contains(column.name), value.isEmptyOrNull { continue }
                values.append((column: column.name, value: value.sqlValue))
            }
            guard !values.isEmpty || allowAllDefaults else { return nil }
            return values
        }
    }
}
