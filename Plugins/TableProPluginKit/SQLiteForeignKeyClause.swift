//
//  SQLiteForeignKeyClause.swift
//  TableProPluginKit
//

import Foundation

/// A foreign key as the stored `CREATE TABLE` text declares it.
///
/// `PRAGMA foreign_key_list` is the usual way to read a table's foreign keys and it cannot answer
/// two questions a schema editor needs. It reports no constraint name, so a key the user named
/// `fk_orders_customer` comes back anonymous and the name they typed is lost on the next read. And
/// it numbers keys positionally, in reverse declaration order, renumbering them whenever one is
/// added or dropped, so a positional id is not an identity that survives an edit.
///
/// Reading the clause out of `sqlite_master.sql` answers both, and it is the same text a rebuild
/// has to rewrite anyway, so the parse is shared rather than duplicated.
public struct SQLiteForeignKeyClause: Sendable, Equatable {
    /// The `CONSTRAINT` name the DDL gave this key, or nil where it was declared without one.
    public let name: String?
    /// The columns in this table. A column-level `REFERENCES` names exactly one.
    public let columns: [String]
    public let referencedTable: String
    /// Empty where the DDL wrote `REFERENCES parent` with no column list, which SQLite reads as
    /// the parent's primary key.
    public let referencedColumns: [String]
    /// The referential action as written, or nil where the DDL omitted the clause. Nil and
    /// `NO ACTION` mean the same thing to SQLite, and are kept apart so a rewrite does not add
    /// words the user did not write.
    public let onDelete: String?
    public let onUpdate: String?

    public init(
        name: String? = nil,
        columns: [String],
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String? = nil,
        onUpdate: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    /// Whether two clauses describe the same relationship, ignoring the name and the actions.
    ///
    /// This is the identity a schema edit can rely on. The name is optional in the DDL and absent
    /// from the pragma, and the actions are what an edit changes, so neither can decide which key
    /// the user asked to drop. Identifiers compare case insensitively, which is how SQLite itself
    /// resolves them.
    public func referencesSameRelationship(as other: SQLiteForeignKeyClause) -> Bool {
        Self.sameIdentifiers(columns, other.columns)
            && Self.sameIdentifier(referencedTable, other.referencedTable)
            && Self.sameIdentifiers(referencedColumns, other.referencedColumns)
    }

    /// The clause as SQLite should store it, with every identifier quoted.
    public var rendered: String {
        var parts: [String] = []
        if let name, !name.isEmpty {
            parts.append("CONSTRAINT \(SQLiteTableDDL.quote(name))")
        }
        parts.append("FOREIGN KEY (\(columns.map(SQLiteTableDDL.quote).joined(separator: ", ")))")
        var reference = "REFERENCES \(SQLiteTableDDL.quote(referencedTable))"
        if !referencedColumns.isEmpty {
            reference += " (\(referencedColumns.map(SQLiteTableDDL.quote).joined(separator: ", ")))"
        }
        parts.append(reference)
        if let onDelete, !onDelete.isEmpty { parts.append("ON DELETE \(onDelete)") }
        if let onUpdate, !onUpdate.isEmpty { parts.append("ON UPDATE \(onUpdate)") }
        return parts.joined(separator: " ")
    }

    private static func sameIdentifier(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private static func sameIdentifiers(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(sameIdentifier)
    }
}

/// Where a foreign key clause sits inside the entry that declares it.
///
/// A table-level `FOREIGN KEY` is a whole entry and is dropped by removing the entry. A
/// column-level `REFERENCES` is part of a column definition, and dropping it means cutting exactly
/// that span out of the column's text and leaving the rest of what the user wrote alone.
internal struct SQLiteLocatedForeignKey: Equatable {
    internal let clause: SQLiteForeignKeyClause
    internal let entryIndex: Int
    /// Nil when the clause is the whole entry.
    internal let spanInEntry: Range<String.Index>?
}

internal enum SQLiteForeignKeyParser {
    private static let actions: [[String]] = [
        ["SET", "NULL"], ["SET", "DEFAULT"], ["CASCADE"], ["RESTRICT"], ["NO", "ACTION"]
    ]

    /// Every foreign key the parsed statement declares, table level and column level alike, in
    /// declaration order.
    internal static func foreignKeys(in parsed: SQLiteTableDDL.Parsed) -> [SQLiteLocatedForeignKey] {
        parsed.entries.enumerated().flatMap { index, entry -> [SQLiteLocatedForeignKey] in
            if let columnName = entry.columnName {
                guard let located = columnLevelForeignKey(in: entry.text, column: columnName) else { return [] }
                return [SQLiteLocatedForeignKey(clause: located.0, entryIndex: index, spanInEntry: located.1)]
            }
            guard let clause = tableLevelForeignKey(in: entry.text) else { return [] }
            return [SQLiteLocatedForeignKey(clause: clause, entryIndex: index, spanInEntry: nil)]
        }
    }

    /// A `[CONSTRAINT name] FOREIGN KEY (cols) REFERENCES ...` entry, or nil for any other table
    /// constraint.
    internal static func tableLevelForeignKey(in text: String) -> SQLiteForeignKeyClause? {
        let tokens = SQLiteTokenizer.tokenize(text)
        var cursor = 0
        var name: String?

        if tokens.first?.keyword == "CONSTRAINT" {
            guard tokens.count > 1 else { return nil }
            name = tokens[1].text
            cursor = 2
        }
        guard cursor + 1 < tokens.count,
              tokens[cursor].keyword == "FOREIGN", tokens[cursor + 1].keyword == "KEY" else { return nil }
        cursor += 2

        guard let (columns, afterColumns) = identifierList(tokens, from: cursor) else { return nil }
        return reference(tokens, from: afterColumns, name: name, columns: columns)
    }

    /// The `REFERENCES ...` clause inside a column definition, with the span it occupies.
    ///
    /// The clause runs from `REFERENCES`, or from the `CONSTRAINT` that names it, to the last
    /// token of the last referential action that follows. Everything else in the column definition
    /// is left exactly as the user wrote it.
    private static func columnLevelForeignKey(
        in text: String,
        column: String
    ) -> (SQLiteForeignKeyClause, Range<String.Index>)? {
        let tokens = SQLiteTokenizer.tokenize(text)
        guard let referencesIndex = tokens.firstIndex(where: { $0.keyword == "REFERENCES" }) else { return nil }

        var start = referencesIndex
        var name: String?
        /// `CONSTRAINT fk_x REFERENCES parent(id)` names the key; a `CONSTRAINT` further back names
        /// some other constraint on the same column and is not part of this clause.
        if referencesIndex >= 2, tokens[referencesIndex - 2].keyword == "CONSTRAINT" {
            name = tokens[referencesIndex - 1].text
            start = referencesIndex - 2
        }

        guard let clause = reference(tokens, from: referencesIndex, name: name, columns: [column]),
              let end = referenceEnd(tokens, from: referencesIndex) else { return nil }
        return (clause, tokens[start].range.lowerBound..<tokens[end].range.upperBound)
    }

    /// Reads `REFERENCES table [(cols)] [ON DELETE x] [ON UPDATE y]` starting at `index`, which must
    /// address the `REFERENCES` keyword.
    private static func reference(
        _ tokens: [SQLiteToken],
        from index: Int,
        name: String?,
        columns: [String]
    ) -> SQLiteForeignKeyClause? {
        guard index < tokens.count, tokens[index].keyword == "REFERENCES", index + 1 < tokens.count else {
            return nil
        }
        let referencedTable = tokens[index + 1].text
        guard !referencedTable.isEmpty, !tokens[index + 1].isPunctuation else { return nil }

        var cursor = index + 2
        var referencedColumns: [String] = []
        if cursor < tokens.count, tokens[cursor].text == "(" {
            guard let (parsed, next) = identifierList(tokens, from: cursor) else { return nil }
            referencedColumns = parsed
            cursor = next
        }

        /// `ON`, `MATCH` and `DEFERRABLE` are alternatives SQLite accepts in any order, so they are
        /// read in one loop. Stopping at the first `MATCH` missed the actions after it:
        /// `REFERENCES p(id) MATCH SIMPLE ON DELETE CASCADE` is legal and its action is real.
        var onDelete: String?
        var onUpdate: String?
        while cursor < tokens.count {
            if cursor + 1 < tokens.count, tokens[cursor].keyword == "ON" {
                let target = tokens[cursor + 1].keyword
                guard target == "DELETE" || target == "UPDATE",
                      let (action, next) = referentialAction(tokens, from: cursor + 2) else { break }
                if target == "DELETE" { onDelete = action } else { onUpdate = action }
                cursor = next
                continue
            }
            if cursor + 1 < tokens.count, tokens[cursor].keyword == "MATCH" {
                cursor += 2
                continue
            }
            if tokens[cursor].keyword == "NOT", cursor + 1 < tokens.count,
               tokens[cursor + 1].keyword == "DEFERRABLE" {
                cursor += 1
                continue
            }
            if tokens[cursor].keyword == "DEFERRABLE" {
                cursor += 1
                if cursor + 1 < tokens.count, tokens[cursor].keyword == "INITIALLY" {
                    let when = tokens[cursor + 1].keyword
                    if when == "DEFERRED" || when == "IMMEDIATE" { cursor += 2 }
                }
                continue
            }
            break
        }

        return SQLiteForeignKeyClause(
            name: name,
            columns: columns,
            referencedTable: referencedTable,
            referencedColumns: referencedColumns,
            onDelete: onDelete,
            onUpdate: onUpdate
        )
    }

    /// The index of the clause's last token, so a column-level clause can be cut out precisely.
    ///
    /// `ON`, `MATCH` and `DEFERRABLE` are alternatives SQLite accepts in any order and any number of
    /// times, so they are read in one repeated loop. Reading them in a fixed order left the tail of
    /// `REFERENCES p(id) MATCH SIMPLE ON DELETE CASCADE` outside the span, and removing the key then
    /// left an orphaned `ON DELETE CASCADE` behind that no `CREATE TABLE` would accept.
    internal static func referenceEnd(_ tokens: [SQLiteToken], from index: Int) -> Int? {
        guard index + 1 < tokens.count else { return nil }
        var cursor = index + 2
        var last = index + 1

        if cursor < tokens.count, tokens[cursor].text == "(" {
            guard let (_, next) = identifierList(tokens, from: cursor) else { return nil }
            last = next - 1
            cursor = next
        }

        while cursor < tokens.count {
            if cursor + 1 < tokens.count, tokens[cursor].keyword == "ON" {
                let target = tokens[cursor + 1].keyword
                guard target == "DELETE" || target == "UPDATE",
                      let (_, next) = referentialAction(tokens, from: cursor + 2) else { break }
                last = next - 1
                cursor = next
                continue
            }
            /// `MATCH` and `DEFERRABLE` are carried along so a rewrite removes all of the key rather
            /// than leaving an orphaned tail behind. TablePro does not model either, and a key that
            /// has one keeps it only while it is untouched.
            if cursor + 1 < tokens.count, tokens[cursor].keyword == "MATCH" {
                last = cursor + 1
                cursor += 2
                continue
            }
            if tokens[cursor].keyword == "NOT", cursor + 1 < tokens.count,
               tokens[cursor + 1].keyword == "DEFERRABLE" {
                cursor += 1
                continue
            }
            if tokens[cursor].keyword == "DEFERRABLE" {
                last = cursor
                cursor += 1
                if cursor + 1 < tokens.count, tokens[cursor].keyword == "INITIALLY" {
                    let when = tokens[cursor + 1].keyword
                    if when == "DEFERRED" || when == "IMMEDIATE" {
                        last = cursor + 1
                        cursor += 2
                    }
                }
                continue
            }
            break
        }
        return last
    }

    private static func referentialAction(_ tokens: [SQLiteToken], from index: Int) -> (String, Int)? {
        for words in actions {
            guard index + words.count <= tokens.count else { continue }
            let candidate = (0..<words.count).map { tokens[index + $0].keyword }
            if candidate == words { return (words.joined(separator: " "), index + words.count) }
        }
        return nil
    }

    /// A parenthesised identifier list starting at `index`, and the index just past its `)`.
    private static func identifierList(_ tokens: [SQLiteToken], from index: Int) -> ([String], Int)? {
        guard index < tokens.count, tokens[index].text == "(" else { return nil }
        var names: [String] = []
        var cursor = index + 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.text == ")" { return names.isEmpty ? nil : (names, cursor + 1) }
            if token.text == "," {
                cursor += 1
                continue
            }
            guard !token.isPunctuation, !token.text.isEmpty else { return nil }
            names.append(token.text)
            cursor += 1
        }
        return nil
    }
}

public extension SQLiteTableDDL {
    /// Every foreign key the statement declares, table level and column level alike, in declaration
    /// order and carrying the name the DDL gave each one.
    static func foreignKeys(in parsed: Parsed) -> [SQLiteForeignKeyClause] {
        SQLiteForeignKeyParser.foreignKeys(in: parsed).map(\.clause)
    }
}
