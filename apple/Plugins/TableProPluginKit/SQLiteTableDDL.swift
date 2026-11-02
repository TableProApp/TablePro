//
//  SQLiteTableDDL.swift
//  TableProPluginKit
//

import Foundation

// Edits the stored CREATE TABLE as text: PRAGMA table_info does not report a column's CHECK, COLLATE or GENERATED clause.
public enum SQLiteTableDDL {
    public struct Entry: Sendable, Equatable {
        public let text: String
        // Nil for a table constraint.
        public let columnName: String?

        public init(text: String, columnName: String?) {
            self.text = text
            self.columnName = columnName
        }
    }

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

    // Nil for anything but an ordinary table: a rebuild would recreate an FTS5 table, whose arguments parse as columns, as a plain one.
    public static func parse(createTableSQL sql: String) -> Parsed? {
        guard let open = topLevelBodyStart(in: sql) else { return nil }
        guard isOrdinaryTable(prefix: sql[sql.startIndex..<open]) else { return nil }
        guard let close = matchingCloseParen(in: sql, from: open) else { return nil }
        let suffix = String(sql[close...])
        guard tableOptions(in: suffix) != nil else { return nil }

        let afterOpen = sql.unicodeScalars.index(after: open)
        let body = String(sql[afterOpen..<close])
        let entries = splitTopLevel(body).map { text -> Entry in
            Entry(text: text, columnName: leadingIdentifier(of: text))
        }
        guard !entries.isEmpty, entries.contains(where: { $0.columnName != nil }) else { return nil }

        return Parsed(
            prefix: String(sql[sql.startIndex..<afterOpen]),
            entries: entries,
            suffix: suffix
        )
    }

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
        guard let options = trailingOptions(of: parsed) else { return nil }

        let indent = "\n  "
        let body = reordered.map { trimmed($0.text) }
            .joined(separator: ",\(indent)")
        return "CREATE TABLE \(quote(tableName)) (\(indent)\(body)\n)\(options)"
    }

    // Only the whitespace beside the cut changes, and a `--` comment before it keeps the line feed that ends it.
    internal static func cuttingSpan(_ span: Range<String.Index>, from text: String) -> String {
        let scalars = text.unicodeScalars
        let headEnd = scalars[..<span.lowerBound].lastIndex(where: { !SQLiteTokenizer.isWhitespace($0) })
            .map { scalars.index(after: $0) } ?? scalars.startIndex
        let tailStart = scalars[span.upperBound...].firstIndex(where: { !SQLiteTokenizer.isWhitespace($0) })
            ?? scalars.endIndex
        let head = String(scalars[..<headEnd])
        let tail = String(scalars[tailStart...])

        let separator: String
        if SQLiteSQLScanner.endsInLineComment(head) {
            separator = "\n"
        } else if head.isEmpty || tail.isEmpty || (headEnd == span.lowerBound && tailStart == span.upperBound) {
            separator = ""
        } else {
            separator = " "
        }
        return head + separator + tail
    }

    // SQLite's whitespace only, and a trailing `--` comment keeps a line feed, or the `,` joined after it is commented out.
    internal static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !SQLiteTokenizer.isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !SQLiteTokenizer.isWhitespace($0) }) else { return "" }
        let kept = String(scalars[first..<scalars.index(after: last)])
        return SQLiteSQLScanner.endsInLineComment(kept) ? kept + "\n" : kept
    }

    public static func quote(_ identifier: String) -> String {
        PluginSQLQuoting.identifier(identifier)
    }

    enum TableOption: String, CaseIterable {
        case withoutRowid = "WITHOUT ROWID"
        case strict = "STRICT"
    }

    // Nil for anything but these options after the `)`: the stored text is never copied, since an open `/*` there swallows the script's next statement.
    static func tableOptions(in suffix: String) -> Set<TableOption>? {
        let scalars = suffix.unicodeScalars
        guard scalars.first == ")" else { return nil }
        let text = String(scalars.dropFirst())
        guard !SQLiteSQLScanner.endsOpen(text) else { return nil }
        let words = SQLiteTokenizer.tokenize(text).map(\.keyword)
        guard !words.isEmpty else { return [] }

        var options: Set<TableOption> = []
        for option in words.split(separator: ",", omittingEmptySubsequences: false) {
            switch Array(option) {
            case ["WITHOUT", "ROWID"]: options.insert(.withoutRowid)
            case ["STRICT"]: options.insert(.strict)
            default: return nil
            }
        }
        return options
    }

    static func trailingOptions(of parsed: Parsed) -> String? {
        guard let options = tableOptions(in: parsed.suffix) else { return nil }
        let written = TableOption.allCases.filter(options.contains).map(\.rawValue)
        return written.isEmpty ? "" : " " + written.joined(separator: ", ")
    }

    // MARK: - Parsing

    private static func isOrdinaryTable(prefix: Substring) -> Bool {
        let words = SQLiteTokenizer.tokenize(String(prefix)).map(\.keyword)
        guard let tableIndex = words.firstIndex(of: "TABLE") else { return false }
        guard words[..<tableIndex].allSatisfy({ ["CREATE", "TEMP", "TEMPORARY"].contains($0) }),
              words.first == "CREATE" else { return false }
        // A bare AS is `CREATE TABLE ... AS SELECT`, which has no column list.
        return !words[tableIndex...].contains("AS")
    }

    // Skips any parenthesis a quoted table name contains.
    private static func topLevelBodyStart(in sql: String) -> String.Index? {
        var scanner = SQLiteSQLScanner(sql)
        while let index = scanner.next() {
            if scanner.isInsideLiteral { continue }
            if sql.unicodeScalars[index] == "(" { return index }
        }
        return nil
    }

    private static func matchingCloseParen(in sql: String, from open: String.Index) -> String.Index? {
        var scanner = SQLiteSQLScanner(sql, from: sql.unicodeScalars.index(after: open))
        var depth = 1
        while let index = scanner.next() {
            if scanner.isInsideLiteral { continue }
            switch sql.unicodeScalars[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    // Ignores the commas inside `DECIMAL(10,2)`, a `CHECK (a IN (1,2))`, a string literal or a quoted identifier.
    private static func splitTopLevel(_ body: String) -> [String] {
        var parts: [String] = []
        var current = body.startIndex
        var depth = 0
        var scanner = SQLiteSQLScanner(body)
        while let index = scanner.next() {
            if scanner.isInsideLiteral { continue }
            switch body.unicodeScalars[index] {
            case "(": depth += 1
            case ")": depth -= 1
            case "," where depth == 0:
                parts.append(String(body[current..<index]))
                current = body.unicodeScalars.index(after: index)
            default: break
            }
        }
        parts.append(String(body[current...]))
        return parts.map { trimmed($0) }.filter { !$0.isEmpty }
    }

    // Nil for a table constraint. A single-quoted name counts: SQLite reports `a` as a column of `CREATE TABLE t('a' TEXT)`.
    private static func leadingIdentifier(of entry: String) -> String? {
        guard let first = SQLiteTokenizer.tokenize(entry).first, !first.isPunctuation else { return nil }
        if first.isQuoted || first.isStringLiteral { return first.text }
        return SQLiteColumnGrammar.tableConstraintKeywords.contains(first.keyword) ? nil : first.text
    }
}
