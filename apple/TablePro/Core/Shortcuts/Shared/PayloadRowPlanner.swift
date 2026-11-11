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
        let columnNames = columns.map(\.name)
        let primaryKeys = Set(columns.filter(\.isPrimaryKey).map(\.name))

        return try rows.compactMap { row in
            let matched = keysByColumn(row.keys, columns: columnNames)
            guard matched.unknown.isEmpty else { throw IntentDataError.unknownColumns(matched.unknown.sorted(), table) }

            var values: [(column: String, value: String?)] = []
            for column in columns {
                guard !column.isServerOwned else { continue }
                guard let key = matched.byColumn[column.name], let value = row.value(for: key) else { continue }
                if dropsEmptyPrimaryKey, primaryKeys.contains(column.name), value.isEmptyOrNull { continue }
                values.append((column: column.name, value: value.sqlValue))
            }
            guard !values.isEmpty || allowAllDefaults else { return nil }
            return values
        }
    }

    // As the import sheet matches a header: its exact spelling claims a column first, then a case-insensitive match.
    // There is no sheet to map a header by hand, so SQL Server's `[name]` also finds `name`.
    static func keysByColumn(_ keys: [String], columns: [String]) -> (byColumn: [String: String], unknown: [String]) {
        var byColumn: [String: String] = [:]
        var loose: [String] = []
        let spelled = Set(columns)
        for key in keys.sorted() {
            if spelled.contains(key) {
                byColumn[key] = key
            } else {
                loose.append(key)
            }
        }
        var unknown: [String] = []
        for key in loose {
            let claimed = byColumn
            guard let column = matchingColumn(for: key, in: columns, unclaimed: { claimed[$0] == nil }) else {
                unknown.append(key)
                continue
            }
            byColumn[column] = key
        }
        return (byColumn, unknown)
    }

    private static func matchingColumn(for key: String, in columns: [String], unclaimed: (String) -> Bool) -> String? {
        for name in [key, unbracketed(key)].compactMap({ $0 }) {
            if columns.contains(name), unclaimed(name) { return name }
            let folded = columns.filter { $0.caseInsensitiveCompare(name) == .orderedSame && unclaimed($0) }
            if folded.count == 1 { return folded[0] }
        }
        return nil
    }

    // `]` inside the brackets is doubled, so a lone one means the key is not a bracketed name.
    private static func unbracketed(_ key: String) -> String? {
        guard key.count > 2, key.hasPrefix("["), key.hasSuffix("]") else { return nil }
        let inner = String(key.dropFirst().dropLast())
        guard !inner.replacingOccurrences(of: "]]", with: "", options: .literal).contains("]") else { return nil }
        return inner.replacingOccurrences(of: "]]", with: "]", options: .literal)
    }
}
