//
//  BatchResultMapping.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// Which statement of a batch stands behind each result set it returned, when that can be known.
///
/// The server does not say. db-lib reads the statement a result came from off the wire and discards it, so a batch
/// is matched to its results only when its shape leaves one answer: nothing but plain queries and the declarations
/// and `SET`s around them, one result set per query. A procedure call, a loop or an assignment `SELECT` breaks the
/// count, and the results are then numbered instead of named.
enum BatchResultMapping {
    private static let declarationKeywords: Set<String> = ["DECLARE", "SET"]

    static func mapsToStatements(
        _ batch: ExecutableBatch,
        resultSetCount: Int,
        hasErrors: Bool,
        isPlainQuery: (String) -> Bool
    ) -> Bool {
        guard batch.repeatCount == 1, !hasErrors else { return false }
        var queryCount = 0
        for statement in batch.statements {
            if isPlainQuery(statement.sql) {
                queryCount += 1
            } else if !declarationKeywords.contains(QueryClassifier.leadingKeyword(of: statement.sql)) {
                return false
            }
        }
        return queryCount == resultSetCount
    }

    /// Whether `sql` reads a local variable or a table variable, which only exists inside the batch that declared it,
    /// so the statement cannot be sent again on its own to fetch more of its rows. `@@ROWCOUNT` and its kin are the
    /// server's own and survive the batch.
    static func referencesLocalVariable(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        var cursor = SQLTokenCursor(sql as NSString, grammar: grammar)
        while let token = cursor.next() {
            guard let word = token.word, word.hasPrefix("@"), !word.hasPrefix("@@"), (word as NSString).length > 1 else {
                continue
            }
            return true
        }
        return false
    }
}

/// What a run of batches has to tell the reader beyond its results: a transaction the script left open, and result
/// sets the driver read past because a batch returned more than it keeps.
enum BatchRunNotice {
    static func text(discardedResultSetCount: Int, sessionState: PluginSessionTransactionState) -> String? {
        let discardedNote = discardedResultSetCount > 0
            ? String(format: String(localized: "%lld more result sets were not kept."), Int64(discardedResultSetCount))
            : nil
        let notes = [sessionState.openTransactionNotice, discardedNote].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// How an error a batch raised reads in the editor.
///
/// The server numbers lines from the first line of the text it was sent, so a batch's line is moved onto the editor's
/// by where the batch starts there. A line inside a procedure counts from that procedure's own text and is left as it
/// came, named after the procedure.
enum BatchErrorText {
    static func describe(_ errors: [PluginBatchError], batchStartLine: Int) -> String? {
        guard !errors.isEmpty else { return nil }
        return errors.map { describe($0, batchStartLine: batchStartLine) }.joined(separator: "\n")
    }

    static func describe(_ error: PluginBatchError, batchStartLine: Int) -> String {
        guard let line = error.line, line > 0 else { return error.message }
        if let procedure = error.procedure, !procedure.isEmpty {
            return String(format: String(localized: "%1$@, line %2$d: %3$@"), procedure, line, error.message)
        }
        return String(format: String(localized: "Line %1$d: %2$@"), batchStartLine + line - 1, error.message)
    }

    /// The 1-based line `location` sits on in `text`. A CRLF counts once, as the server counts it.
    static func line(of location: Int, in text: String) -> Int {
        lines(of: [location], in: text)[0]
    }

    /// The line of each location, in one pass over `text`. `locations` must be ascending, as a script's batches are.
    static func lines(of locations: [Int], in text: String) -> [Int] {
        let source = text as NSString
        var lines: [Int] = []
        lines.reserveCapacity(locations.count)
        var line = 1
        var index = 0
        for location in locations {
            let end = min(max(location, 0), source.length)
            while index < end {
                let character = source.character(at: index)
                if character == Self.lineFeed {
                    line += 1
                } else if character == Self.carriageReturn,
                          index + 1 >= source.length || source.character(at: index + 1) != Self.lineFeed {
                    line += 1
                }
                index += 1
            }
            lines.append(line)
        }
        return lines
    }

    private static let lineFeed = UInt16(0x0A)
    private static let carriageReturn = UInt16(0x0D)
}
