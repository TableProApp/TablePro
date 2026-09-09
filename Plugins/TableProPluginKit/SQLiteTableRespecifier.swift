//
//  SQLiteTableRespecifier.swift
//  TableProPluginKit
//

import Foundation

/// The `CREATE TABLE` a respecification asks for, and what the change costs.
public struct SQLiteRespecifiedTable: Sendable, Equatable {
    /// One column of the rebuilt table that carries data over from the original.
    public struct CarriedColumn: Sendable, Equatable {
        public let name: String
        public let sourceName: String

        public init(name: String, sourceName: String) {
            self.name = name
            self.sourceName = sourceName
        }
    }

    public let createTableSQL: String

    /// The columns the rebuilt table shares with the original, in the rebuilt table's order. A
    /// column the save adds is absent: there is nothing to copy into it.
    public let carriedColumns: [CarriedColumn]

    /// What the rewrite could not carry across, phrased for the user. Empty is the normal case.
    public let caveats: [String]

    public init(createTableSQL: String, carriedColumns: [CarriedColumn], caveats: [String]) {
        self.createTableSQL = createTableSQL
        self.carriedColumns = carriedColumns
        self.caveats = caveats
    }
}

public extension SQLiteTableDDL {
    /// The statement that creates `tableName` as `respecification` asks for.
    ///
    /// Every entry the respecification does not touch keeps its source text byte for byte, which is
    /// what carries a `CHECK`, a `COLLATE`, a `GENERATED ALWAYS AS` and a `DEFAULT` containing a
    /// comma through a rebuild. Only an entry the save actually changes is rewritten.
    ///
    /// Nil when the respecification cannot be applied to this statement: a column it renames or
    /// drops that the statement does not define, or a wanted order that is not a permutation of the
    /// columns that result.
    static func respecified(
        _ parsed: Parsed,
        tableName: String,
        respecification: PluginTableRespecification,
        renderColumn: (PluginColumnDefinition) -> String
    ) -> SQLiteRespecifiedTable? {
        var caveats: [String] = []
        let existingNames = parsed.columnNames

        guard respecification.droppedColumns.allSatisfy({ contains(existingNames, $0) }),
              respecification.renamedColumns.keys.allSatisfy({ contains(existingNames, $0) }) else {
            return nil
        }

        let located = SQLiteForeignKeyParser.foreignKeys(in: parsed)
        guard let removals = foreignKeyRemovals(
            located: located,
            dropping: respecification.droppedForeignKeys,
            droppedColumns: respecification.droppedColumns
        ) else { return nil }

        /// A key is edited by removing its clause and writing a new one from the editable model,
        /// which carries the columns, the table and the two actions and nothing else. A key that
        /// also declared `MATCH` or `DEFERRABLE` loses it, so it is named rather than lost quietly.
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
                text = cutting(span, from: text)
            }
            let finalName = matchedRename(of: columnName, in: respecification.renamedColumns) ?? columnName
            if finalName != columnName {
                text = renamingLeadingIdentifier(of: text, to: finalName) ?? text
            }
            columnEntries.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            carried.append(SQLiteRespecifiedTable.CarriedColumn(name: finalName, sourceName: columnName))
        }

        for column in respecification.addedColumns {
            let rendered = renderColumn(column).trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard !orderedColumns.isEmpty else { return nil }

        let indent = "\n  "
        let body = (orderedColumns + constraintEntries).joined(separator: ",\(indent)")
        return SQLiteRespecifiedTable(
            createTableSQL: "CREATE TABLE \(quote(tableName)) (\(indent)\(body)\n)\(trailingOptions(of: parsed))",
            carriedColumns: orderedCarried,
            caveats: caveats
        )
    }

    /// Whether the statement declares a rowid, which decides whether a rebuild can carry rowids
    /// across. A `WITHOUT ROWID` table has none to carry.
    static func isRowidTable(_ parsed: Parsed) -> Bool {
        let trailing = parsed.suffix
            .split(whereSeparator: { $0.isWhitespace || $0 == ")" || $0 == "," })
            .map { $0.uppercased() }
        guard let withoutIndex = trailing.firstIndex(of: "WITHOUT") else { return true }
        return trailing.index(after: withoutIndex) >= trailing.endIndex
            || trailing[trailing.index(after: withoutIndex)] != "ROWID"
    }
}

// MARK: - Respecification internals

private extension SQLiteTableDDL {
    struct ForeignKeyRemovals {
        var wholeEntries: Set<Int> = []
        var spans: [Int: Range<String.Index>] = [:]

        /// Whether any clause being removed declared something the editable model cannot carry.
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

    /// Which entries a foreign key drop removes, and which column definitions lose a span.
    ///
    /// Nil when a key the save asks to drop is not in the statement, because rebuilding without it
    /// would report success over a key that is still there.
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

        /// A key whose own column is going away cannot survive the rebuild, and leaving it in makes
        /// the `CREATE TABLE` invalid rather than making the drop fail.
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

    /// A table constraint entry with any renamed column carried into it.
    ///
    /// A foreign key is re-rendered from its parsed form, which is the only way to rewrite the
    /// column names inside it; that drops a `MATCH` or `DEFERRABLE` clause TablePro does not model,
    /// so it says so. Every other table constraint keeps its text, because a rename inside a
    /// `CHECK` expression cannot be rewritten without understanding the expression.
    static func rewrittenConstraint(
        entry: Entry,
        index: Int,
        located: [SQLiteLocatedForeignKey],
        renames: [String: String],
        caveats: inout [String]
    ) -> String? {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// `NO ACTION` is SQLite's behaviour with no clause at all, so it is written as no clause. That
    /// keeps a rebuilt statement as close to what the user wrote as the edit allows.
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

    /// The declaration with `span` removed and the gap it left closed.
    ///
    /// Only the whitespace either side of the cut is touched. Collapsing runs across the whole
    /// declaration would rewrite text the user typed: a `DEFAULT 'a  b'` elsewhere in the same
    /// column would come back with one space instead of two.
    static func cutting(_ span: Range<String.Index>, from text: String) -> String {
        var head = String(text[text.startIndex..<span.lowerBound])
        let tail = String(text[span.upperBound...])
        let headHadSpace = head.last?.isWhitespace ?? false
        let tailHasSpace = tail.first?.isWhitespace ?? false
        while head.last?.isWhitespace == true { head.removeLast() }
        let separator = head.isEmpty || tail.isEmpty || !(headHadSpace || tailHasSpace) ? "" : " "
        return head + separator + tail.drop(while: { $0.isWhitespace })
    }

    /// The same column definition under a new name, with everything after the name untouched.
    static func renamingLeadingIdentifier(of text: String, to name: String) -> String? {
        guard let first = SQLiteTokenizer.tokenize(text).first else { return nil }
        return text.replacingCharacters(in: first.range, with: quote(name))
    }

    static func trailingOptions(of parsed: Parsed) -> String {
        let trailing = parsed.suffix.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return trailing.isEmpty ? "" : " \(trailing)"
    }
}
