//
//  LibPQCappedCursorRead.swift
//  PostgreSQLDriverPlugin
//

import Foundation

// A capped read for a session that cannot cancel: inside the user's transaction block a cancel aborts the block, and
// a single-connection server takes none. Single-row mode only changes how libpq hands rows over, so the server would
// still send every row. Through a cursor, FETCH sends the cap's rows and MOVE runs the rest without sending them, so
// every row's side effects still happen, as they did when the tail was drained.
internal enum LibPQCappedCursorRead {
    enum Scope: Equatable {
        // A savepoint holds the cursor, so a refused DECLARE leaves the user's block as it was.
        case insideTransaction
        // DECLARE needs a transaction block, so the read opens and commits one of its own.
        case ownTransaction
    }

    struct Plan: Equatable {
        let scope: Scope
        // Its own round trip: the server parses a whole query string before it runs any of it, so a syntax error in
        // the user's text would otherwise leave no savepoint to roll back to.
        let opening: String
        let statement: String
        // Undoes the attempt, so a refused cursor can run again the plain way.
        let recovery: String
        let fetchCount: Int
    }

    static let cursorName = "tablepro_capped_read"

    private static let cursorableKeywords: Set<String> = ["select", "with", "values", "table"]

    // DECLARE refuses INTO and a data-modifying WITH, and a rolled-back stream savepoint would drop the locks of FOR
    // UPDATE and FOR SHARE. A false match costs nothing but the plain read.
    private static let excludedWords: Set<String> = ["into", "insert", "update", "delete", "merge", "share"]

    static func plan(for query: String, rowCap: Int, scope: Scope) -> Plan? {
        guard rowCap > 0, rowCap < Int(Int32.max), let body = cursorBody(of: query) else { return nil }
        let fetchCount = rowCap + 1
        let opening: String
        let closing: String
        let recovery: String
        switch scope {
        case .insideTransaction:
            opening = "SAVEPOINT \(cursorName)"
            closing = "RELEASE SAVEPOINT \(cursorName)"
            recovery = "ROLLBACK TO SAVEPOINT \(cursorName); RELEASE SAVEPOINT \(cursorName)"
        case .ownTransaction:
            opening = "BEGIN"
            closing = "COMMIT"
            recovery = "ROLLBACK"
        }
        // The body sits on lines of its own, so a trailing `--` comment cannot swallow the FETCH.
        let statement = [
            "DECLARE \(cursorName) NO SCROLL CURSOR FOR",
            body,
            ";",
            "FETCH FORWARD \(fetchCount) FROM \(cursorName);",
            "MOVE FORWARD ALL FROM \(cursorName);",
            "CLOSE \(cursorName);",
            closing,
        ].joined(separator: "\n")
        return Plan(scope: scope, opening: opening, statement: statement, recovery: recovery, fetchCount: fetchCount)
    }

    // One SELECT, VALUES or TABLE statement, without its trailing semicolons. Any other semicolon, even one inside a
    // literal or a comment, sends the text the plain way rather than risk a second statement inside the cursor.
    static func cursorBody(of query: String) -> String? {
        var body = Substring(query)
        while let last = body.last, last.isWhitespace || last == ";" {
            body = body.dropLast()
        }
        guard !body.isEmpty, !body.contains(";") else { return nil }
        guard let keyword = leadingKeyword(of: body), cursorableKeywords.contains(keyword) else { return nil }
        let words = body.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
        guard !words.contains(where: { excludedWords.contains(String($0)) }) else { return nil }
        return String(body)
    }

    private static func leadingKeyword(of text: Substring) -> String? {
        var rest = text[...]
        while let first = rest.first {
            if first.isWhitespace || first == "(" {
                rest = rest.dropFirst()
            } else if rest.hasPrefix("--") {
                guard let lineEnd = rest.firstIndex(where: \.isNewline) else { return nil }
                rest = rest[lineEnd...]
            } else if rest.hasPrefix("/*") {
                guard let commentEnd = rest.range(of: "*/") else { return nil }
                rest = rest[commentEnd.upperBound...]
            } else {
                break
            }
        }
        let word = rest.prefix { $0.isLetter }
        return word.isEmpty ? nil : word.lowercased()
    }
}
