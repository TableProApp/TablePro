//
//  SQLiteTableRespecifier.swift
//  TableProPluginKit
//

import Foundation

public struct SQLiteRespecifiedTable: Sendable, Equatable {
    public struct CarriedColumn: Sendable, Equatable {
        public let name: String
        public let sourceName: String

        public init(name: String, sourceName: String) {
            self.name = name
            self.sourceName = sourceName
        }
    }

    public let createTableSQL: String

    // A column the save adds is absent: there is nothing to copy into it.
    public let carriedColumns: [CarriedColumn]

    // What the rewrite could not carry across, phrased for the user.
    public let caveats: [String]

    public init(createTableSQL: String, carriedColumns: [CarriedColumn], caveats: [String]) {
        self.createTableSQL = createTableSQL
        self.carriedColumns = carriedColumns
        self.caveats = caveats
    }
}

public extension SQLiteTableDDL {
    // An entry the save does not touch keeps its stored text, which carries what no catalog query reports.
    static func respecified(
        _ parsed: Parsed,
        tableName: String,
        respecification: PluginTableRespecification,
        renderColumn: (PluginColumnDefinition) -> String
    ) -> SQLiteRespecifiedTable? {
        var caveats: [String] = []
        let existingNames = parsed.columnNames

        guard respecification.droppedColumns.allSatisfy({ contains(existingNames, $0) }),
              respecification.renamedColumns.keys.allSatisfy({ contains(existingNames, $0) }),
              respecification.alteredColumns.allSatisfy({ contains(existingNames, $0.column) }) else {
            return nil
        }

        let rowidAlias = rowidAliasColumn(parsed)
        let located = SQLiteForeignKeyParser.foreignKeys(in: parsed)
        guard let removals = foreignKeyRemovals(
            located: located,
            dropping: respecification.droppedForeignKeys,
            droppedColumns: respecification.droppedColumns
        ) else { return nil }

        // The editable model has no MATCH or DEFERRABLE, so a replaced key loses them.
        if removals.carriesUnmodelledClause(in: parsed) {
            caveats.append(
                String(localized: "A replaced foreign key does not keep its MATCH or DEFERRABLE clause.")
            )
        }

        var carried: [SQLiteRespecifiedTable.CarriedColumn] = []
        var columnEntries: [String] = []
        var constraintEntries: [String] = []

        for (index, entry) in parsed.entries.enumerated() {
            guard let columnName = entry.columnName else {
                if removals.wholeEntries.contains(index) { continue }
                guard let rewritten = rewrittenConstraint(
                    entry: entry,
                    index: index,
                    located: located,
                    renames: respecification.renamedColumns,
                    caveats: &caveats
                ) else { continue }
                constraintEntries.append(rewritten)
                continue
            }
            if contains(respecification.droppedColumns, columnName) { continue }

            var text = entry.text
            if let span = removals.spans[index] {
                text = cuttingSpan(span, from: text)
            }
            if let alteration = respecification.alteredColumns.first(
                where: { $0.column.compare(columnName, options: .caseInsensitive) == .orderedSame }
            ) {
                guard let rewritten = SQLiteColumnDeclaration.rewritten(
                    text,
                    applying: SQLiteColumnDeclaration.Edit(
                        type: alteration.type,
                        isNullable: alteration.isNullable,
                        defaultValue: alteration.defaultValue
                    ),
                    isRowidAlias: rowidAlias.map {
                        $0.compare(columnName, options: .caseInsensitive) == .orderedSame
                    } ?? false
                ) else { return nil }
                text = rewritten
            }
            let finalName = matchedRename(of: columnName, in: respecification.renamedColumns) ?? columnName
            if finalName != columnName {
                text = renamingLeadingIdentifier(of: text, to: finalName) ?? text
            }
            columnEntries.append(trimmed(text))
            carried.append(SQLiteRespecifiedTable.CarriedColumn(name: finalName, sourceName: columnName))
        }

        for column in respecification.addedColumns {
            let rendered = trimmed(renderColumn(column))
            guard !rendered.isEmpty else { return nil }
            columnEntries.append(rendered)
        }
        for foreignKey in respecification.addedForeignKeys {
            constraintEntries.append(clause(for: foreignKey).rendered)
        }

        var orderedColumns = columnEntries
        var orderedCarried = carried
        if let wanted = respecification.columnOrder {
            guard let reordered = reorder(
                columnEntries: columnEntries,
                carried: carried,
                addedColumns: respecification.addedColumns,
                to: wanted
            ) else { return nil }
            orderedColumns = reordered.0
            orderedCarried = reordered.1
        }

        guard !orderedColumns.isEmpty, let options = trailingOptions(of: parsed) else { return nil }

        let indent = "\n  "
        let body = (orderedColumns + constraintEntries).joined(separator: ",\(indent)")
        return SQLiteRespecifiedTable(
            createTableSQL: "CREATE TABLE \(quote(tableName)) (\(indent)\(body)\n)\(options)",
            carriedColumns: orderedCarried,
            caveats: caveats
        )
    }

    // The key may be declared at table level: `CREATE TABLE t(id INTEGER, PRIMARY KEY(id))` makes `id` the rowid too.
    static func rowidAliasColumn(_ parsed: Parsed) -> String? {
        guard isRowidTable(parsed) else { return nil }

        var keyColumns: [String] = []
        for entry in parsed.entries {
            guard let declaration = SQLiteColumnDeclaration.parse(entry.text) else {
                guard let tableLevel = tableLevelPrimaryKeyColumns(entry.text) else { continue }
                keyColumns = tableLevel
                continue
            }
            if declaration.constraints.contains(where: { $0.kind == .primaryKey }) {
                keyColumns = [declaration.name]
            }
        }

        guard keyColumns.count == 1, let name = keyColumns.first else { return nil }
        guard let declaration = parsed.entries.lazy
            .compactMap({ SQLiteColumnDeclaration.parse($0.text) })
            .first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
            return nil
        }
        let type = declaration.declaredType ?? ""
        return type.caseInsensitiveCompare("INTEGER") == .orderedSame ? declaration.name : nil
    }

    // Nil for any table constraint other than PRIMARY KEY.
    private static func tableLevelPrimaryKeyColumns(_ text: String) -> [String]? {
        let tokens = SQLiteTokenizer.tokenize(text)
        var cursor = 0
        if tokens.first?.keyword == "CONSTRAINT" { cursor = 2 }
        guard cursor + 2 < tokens.count,
              tokens[cursor].keyword == "PRIMARY", tokens[cursor + 1].keyword == "KEY" else { return nil }

        var names: [String] = []
        var index = cursor + 3
        while index < tokens.count, tokens[index].text != ")" {
            if !tokens[index].isPunctuation, !["ASC", "DESC", "COLLATE"].contains(tokens[index].keyword) {
                if index == cursor + 3 || tokens[index - 1].text == "," { names.append(tokens[index].text) }
            }
            index += 1
        }
        return names.isEmpty ? nil : names
    }

    // The options the rebuild writes: SQLite stores a comment between them, `) /* WITHOUT ROWID */ STRICT`.
    static func isRowidTable(_ parsed: Parsed) -> Bool {
        tableOptions(in: parsed.suffix)?.contains(.withoutRowid) != true
    }
}

// MARK: - Respecification internals

private extension SQLiteTableDDL {
    struct ForeignKeyRemovals {
        var wholeEntries: Set<Int> = []
        var spans: [Int: Range<String.Index>] = [:]

        func carriesUnmodelledClause(in parsed: Parsed) -> Bool {
            let whole = wholeEntries.compactMap { index in
                parsed.entries.indices.contains(index) ? parsed.entries[index].text : nil
            }
            let partial = spans.compactMap { index, span -> String? in
                guard parsed.entries.indices.contains(index) else { return nil }
                return String(parsed.entries[index].text[span])
            }
            return (whole + partial).contains { text in
                text.range(of: "MATCH", options: .caseInsensitive) != nil
                    || text.range(of: "DEFERRABLE", options: .caseInsensitive) != nil
            }
        }
    }

    // Nil when a key to drop is not in the statement: the rebuild would report success over a key that is still there.
    static func foreignKeyRemovals(
        located: [SQLiteLocatedForeignKey],
        dropping: [PluginForeignKeyDefinition],
        droppedColumns: [String]
    ) -> ForeignKeyRemovals? {
        var removals = ForeignKeyRemovals()
        var claimed: Set<Int> = []

        for definition in dropping {
            let wanted = clause(for: definition)
            guard let match = located.enumerated().first(where: { index, candidate in
                !claimed.contains(index) && candidate.clause.referencesSameRelationship(as: wanted)
            }) else { return nil }
            claimed.insert(match.offset)
            record(match.element, into: &removals)
        }

        // A key on a dropped column would leave the CREATE TABLE invalid.
        for (index, candidate) in located.enumerated() where !claimed.contains(index) {
            guard candidate.clause.columns.contains(where: { column in
                droppedColumns.contains { $0.compare(column, options: .caseInsensitive) == .orderedSame }
            }) else { continue }
            record(candidate, into: &removals)
        }
        return removals
    }

    static func record(_ located: SQLiteLocatedForeignKey, into removals: inout ForeignKeyRemovals) {
        if let span = located.spanInEntry {
            removals.spans[located.entryIndex] = span
        } else {
            removals.wholeEntries.insert(located.entryIndex)
        }
    }

    // Only a foreign key is re-rendered: a rename inside a CHECK expression cannot be rewritten without parsing it.
    static func rewrittenConstraint(
        entry: Entry,
        index: Int,
        located: [SQLiteLocatedForeignKey],
        renames: [String: String],
        caveats: inout [String]
    ) -> String? {
        let text = trimmed(entry.text)
        guard !renames.isEmpty,
              let match = located.first(where: { $0.entryIndex == index && $0.spanInEntry == nil }) else {
            return text
        }
        let renamed = match.clause.columns.map { matchedRename(of: $0, in: renames) ?? $0 }
        guard renamed != match.clause.columns else { return text }

        let rewritten = SQLiteForeignKeyClause(
            name: match.clause.name,
            columns: renamed,
            referencedTable: match.clause.referencedTable,
            referencedColumns: match.clause.referencedColumns,
            onDelete: match.clause.onDelete,
            onUpdate: match.clause.onUpdate
        )
        if text.range(of: "MATCH", options: [.caseInsensitive]) != nil
            || text.range(of: "DEFERRABLE", options: [.caseInsensitive]) != nil {
            caveats.append(
                String(
                    localized: "A renamed column's foreign key is rewritten, so its MATCH and DEFERRABLE clauses are not carried over."
                )
            )
        }
        return rewritten.rendered
    }

    static func reorder(
        columnEntries: [String],
        carried: [CarriedColumnEntry],
        addedColumns: [PluginColumnDefinition],
        to wanted: [String]
    ) -> ([String], [SQLiteRespecifiedTable.CarriedColumn])? {
        let names = carried.map(\.name) + addedColumns.map(\.name)
        guard names.count == columnEntries.count, names.count == wanted.count else { return nil }

        var entryByName: [String: String] = [:]
        var carriedByName: [String: SQLiteRespecifiedTable.CarriedColumn] = [:]
        for (offset, name) in names.enumerated() {
            entryByName[name.lowercased()] = columnEntries[offset]
            if offset < carried.count { carriedByName[name.lowercased()] = carried[offset] }
        }

        var orderedEntries: [String] = []
        var orderedCarried: [SQLiteRespecifiedTable.CarriedColumn] = []
        for name in wanted {
            guard let entry = entryByName[name.lowercased()] else { return nil }
            orderedEntries.append(entry)
            if let column = carriedByName[name.lowercased()] { orderedCarried.append(column) }
        }
        return (orderedEntries, orderedCarried)
    }

    typealias CarriedColumnEntry = SQLiteRespecifiedTable.CarriedColumn

    static func clause(for definition: PluginForeignKeyDefinition) -> SQLiteForeignKeyClause {
        SQLiteForeignKeyClause(
            name: definition.name.isEmpty ? nil : definition.name,
            columns: definition.columns,
            referencedTable: definition.referencedTable,
            referencedColumns: definition.referencedColumns,
            onDelete: normalized(definition.onDelete),
            onUpdate: normalized(definition.onUpdate)
        )
    }

    // `NO ACTION` is what no clause means, so it is written as none.
    static func normalized(_ action: String) -> String? {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty || trimmed == "NO ACTION" ? nil : trimmed
    }

    static func contains(_ names: [String], _ name: String) -> Bool {
        names.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    static func matchedRename(of column: String, in renames: [String: String]) -> String? {
        renames.first { $0.key.compare(column, options: .caseInsensitive) == .orderedSame }?.value
    }

    static func renamingLeadingIdentifier(of text: String, to name: String) -> String? {
        guard let first = SQLiteTokenizer.tokenize(text).first else { return nil }
        return text.replacingCharacters(in: first.range, with: quote(name))
    }
}
