//
//  SQLiteTableDDL.swift
//  TableProPluginKit
//

import Foundation

/// Reads and rewrites the `CREATE TABLE` text SQLite stores for a table.
///
/// SQLite keeps the statement the user wrote, verbatim, in `sqlite_master.sql`. Reordering a
/// table's columns by moving those definitions as text is the only way to keep everything they
/// carry: a `CHECK`, a `COLLATE`, a `GENERATED ALWAYS AS`, a `DEFAULT 'a, b'` with a comma inside
/// it. Re-rendering a column from `PRAGMA table_info` instead loses all four, because the pragma
/// does not report them.
///
/// Shared by every SQLite-derived driver. libSQL, Turso and Cloudflare D1 all answer the same
/// `sqlite_master` query, so they get the same rewrite rather than three copies of it.
public enum SQLiteTableDDL {
    /// One top-level entry inside the parentheses of a `CREATE TABLE`.
    public struct Entry: Sendable, Equatable {
        /// The entry's source text, exactly as SQLite stored it.
        public let text: String
        /// The column this entry defines, or nil for a table constraint.
        public let columnName: String?

        public init(text: String, columnName: String?) {
            self.text = text
            self.columnName = columnName
        }
    }

    /// A parsed `CREATE TABLE`, kept as the three pieces a reorder needs to reassemble it.
    public struct Parsed: Sendable, Equatable {
        public let prefix: String
        public let entries: [Entry]
        public let suffix: String

        public init(prefix: String, entries: [Entry], suffix: String) {
            self.prefix = prefix
            self.entries = entries
            self.suffix = suffix
        }

        public var columnNames: [String] { entries.compactMap(\.columnName) }
    }

    private static let tableConstraintKeywords: Set<String> = [
        "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"
    ]

    /// Splits `CREATE TABLE x (…) WITHOUT ROWID` into its prefix, its top-level entries and its
    /// trailing options.
    ///
    /// Nil for anything that is not an ordinary table, because a rebuild of one of those destroys
    /// it. `sqlite_master` stores an FTS5 table as `CREATE VIRTUAL TABLE docs USING fts5(title,
    /// body)`, whose parentheses parse exactly like a column list, so accepting it would recreate
    /// the table as a plain one and take the index and its shadow tables down with the `DROP`.
    /// `CREATE TABLE … AS SELECT` has no column list to reorder either.
    public static func parse(createTableSQL sql: String) -> Parsed? {
        guard let open = topLevelBodyStart(in: sql) else { return nil }
        guard isOrdinaryTable(prefix: sql[sql.startIndex..<open]) else { return nil }
        guard let close = matchingCloseParen(in: sql, from: open) else { return nil }

        let body = String(sql[sql.index(after: open)..<close])
        let entries = splitTopLevel(body).map { text -> Entry in
            Entry(text: text, columnName: leadingIdentifier(of: text))
        }
        guard !entries.isEmpty, entries.contains(where: { $0.columnName != nil }) else { return nil }

        return Parsed(
            prefix: String(sql[sql.startIndex...open]),
            entries: entries,
            suffix: String(sql[close...])
        )
    }

    /// The same statement with its column definitions in `desiredOrder` and everything else where
    /// it was. Nil when the wanted order is not a permutation of the columns the statement defines.
    public static func reordered(_ parsed: Parsed, to desiredOrder: [String], tableName: String) -> String? {
        let byName = Dictionary(
            parsed.entries.compactMap { entry in entry.columnName.map { ($0, entry) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard byName.count == desiredOrder.count,
              desiredOrder.allSatisfy({ byName[$0] != nil }) else { return nil }

        var reordered: [Entry] = []
        var columnCursor = desiredOrder.makeIterator()
        for entry in parsed.entries {
            guard entry.columnName != nil else {
                reordered.append(entry)
                continue
            }
            guard let next = columnCursor.next(), let replacement = byName[next] else { return nil }
            reordered.append(replacement)
        }

        let indent = "\n  "
        let body = reordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ",\(indent)")
        return "CREATE TABLE \(quote(tableName)) (\(indent)\(body)\n)\(trailingOptions(of: parsed))"
    }

    public static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Parsing

    private static func trailingOptions(of parsed: Parsed) -> String {
        let trailing = parsed.suffix.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return trailing.isEmpty ? "" : " \(trailing)"
    }

    /// Whether what stands before the column list is a plain `CREATE TABLE`. Only the keywords
    /// SQLite allows there are accepted, so an unrecognised form is refused rather than rebuilt.
    private static func isOrdinaryTable(prefix: Substring) -> Bool {
        let words = prefix
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.uppercased() }
        guard let tableIndex = words.firstIndex(of: "TABLE") else { return false }
        /// Only these may stand before TABLE. VIRTUAL does not, which is what rules out an FTS or
        /// R-tree table whose module arguments would otherwise read as a column list.
        guard words[..<tableIndex].allSatisfy({ ["CREATE", "TEMP", "TEMPORARY"].contains($0) }),
              words.first == "CREATE" else { return false }
        /// What follows is `IF NOT EXISTS` and a name, which may itself be several whitespace
        /// separated tokens when it is quoted. A bare AS among them is `CREATE TABLE … AS SELECT`,
        /// which has no column list to reorder.
        return !words[tableIndex...].contains("AS")
    }

    /// The opening parenthesis of the column list, skipping any that a quoted table name contains.
    private static func topLevelBodyStart(in sql: String) -> String.Index? {
        var scanner = SQLiteSQLScanner(sql)
        while let index = scanner.next() {
            if scanner.isInsideLiteral { continue }
            if sql[index] == "(" { return index }
        }
        return nil
    }

    private static func matchingCloseParen(in sql: String, from open: String.Index) -> String.Index? {
        var scanner = SQLiteSQLScanner(sql, from: sql.index(after: open))
        var depth = 1
        while let index = scanner.next() {
            if scanner.isInsideLiteral { continue }
            switch sql[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// Splits on the commas that separate entries, ignoring the ones inside `DECIMAL(10,2)`, a
    /// `CHECK (a IN (1,2))`, a string literal or a quoted identifier.
    private static func splitTopLevel(_ body: String) -> [String] {
        var parts: [String] = []
        var current = body.startIndex
        var depth = 0
        var scanner = SQLiteSQLScanner(body)
        while let index = scanner.next() {
            if scanner.isInsideLiteral { continue }
            switch body[index] {
            case "(": depth += 1
            case ")": depth -= 1
            case "," where depth == 0:
                parts.append(String(body[current..<index]))
                current = body.index(after: index)
            default: break
            }
        }
        parts.append(String(body[current...]))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The column an entry defines, or nil when the entry is a table constraint.
    private static func leadingIdentifier(of entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }

        if let closing = closingQuote(for: first) {
            var name = ""
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character == closing {
                    let next = trimmed.index(after: index)
                    /// A doubled quote is an escaped one, not the end of the identifier.
                    if next < trimmed.endIndex, trimmed[next] == closing, closing != "]" {
                        name.append(character)
                        index = trimmed.index(after: next)
                        continue
                    }
                    return name
                }
                name.append(character)
                index = trimmed.index(after: index)
            }
            return nil
        }

        let word = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        guard !word.isEmpty else { return nil }
        return tableConstraintKeywords.contains(word.uppercased()) ? nil : String(word)
    }

    private static func closingQuote(for opening: Character) -> Character? {
        switch opening {
        case "\"": "\""
        case "`": "`"
        case "[": "]"
        default: nil
        }
    }

}
