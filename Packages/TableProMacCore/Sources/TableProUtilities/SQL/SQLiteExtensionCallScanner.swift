//
//  SQLiteExtensionCallScanner.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

/// Whether a statement calls anything but what SQLite itself provides.
///
/// A loaded extension adds functions that can do anything native code can: SpatiaLite's
/// `BlobToFile` writes a file, and an `eval()` runs a nested statement the classifier never sees.
/// So a statement from outside the app's own windows may reach an extension-loading connection only
/// when every call in it names a built-in. The scan is deliberately conservative: a callee it cannot
/// name, such as a quoted identifier in front of a parenthesis, counts as a call it cannot vouch for.
/// SQLite accepts `"abs"(1)`, `` `abs`(1) ``, `[abs](1)` and a comment between a name and its
/// parenthesis (measured on 3.53.4), so all of those are recognized as calls.
enum SQLiteExtensionCallScanner {
    static func callsOnlyBuiltins(_ sql: String, readings: SQLLexicalReadings) -> Bool {
        readings.distinct(for: sql).allSatisfy { grammar in
            callsOnlyBuiltins(sql, grammar: grammar)
        }
    }

    static func callsOnlyBuiltins(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        let code = SQLCodeProjection.code(of: sql, grammar: grammar, revealingExecutableComments: true) as NSString
        return SQLFunctionCallScanner.calls(in: sql as NSString, code: code).allSatisfy { call in
            guard case .named(let name, let start) = call.callee else { return false }
            return isBuiltinOrSyntax(name)
                || isColumnList(nameStart: start, parenthesis: call.parenthesis, code: code)
        }
    }

    static func isBuiltinOrSyntax(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return SQLiteBuiltinNames.functions.contains(lowered)
            || SQLiteBuiltinNames.tableValuedFunctions.contains(lowered)
            || SQLiteBuiltinNames.keywords.contains(lowered)
            || lowered.hasPrefix("pragma_")
    }

    /// A parenthesis that opens a column list rather than a call: `INSERT INTO t(id)`,
    /// `CREATE TABLE t(...)`, `CREATE VIEW v(x)`, `REFERENCES t(id)`, `IF NOT EXISTS t(...)`, and a
    /// common table expression's `WITH ids(id) AS (...)`. SQLite rejects a call after each of those
    /// words (measured), and a call followed by `AS` names a column, never a `(`. A virtual table's
    /// `USING module(` is not among them: an extension's module can read files.
    private static let columnListIntroducers: Set<String> = ["INTO", "TABLE", "VIEW", "REFERENCES", "EXISTS"]

    private static func isColumnList(nameStart: Int, parenthesis: Int, code: NSString) -> Bool {
        if let previous = wordBefore(nameStart, code: code), columnListIntroducers.contains(previous) {
            return true
        }
        return opensCommonTableExpressionColumns(parenthesis, code: code)
    }

    /// The keyword in front of a name, past a `schema.` qualifier.
    private static func wordBefore(_ start: Int, code: NSString) -> String? {
        var cursor = skipBlanksBackward(from: start - 1, code: code)
        if cursor >= 0, code.character(at: cursor) == UInt16(UnicodeScalar(".").value) {
            cursor = skipBlanksBackward(from: cursor - 1, code: code)
            while cursor >= 0, SQLFunctionCallScanner.isIdentifierUnit(code.character(at: cursor)) {
                cursor -= 1
            }
            cursor = skipBlanksBackward(from: cursor, code: code)
        }
        guard cursor >= 0, SQLFunctionCallScanner.isIdentifierUnit(code.character(at: cursor)) else { return nil }
        var wordStart = cursor
        while wordStart > 0, SQLFunctionCallScanner.isIdentifierUnit(code.character(at: wordStart - 1)) {
            wordStart -= 1
        }
        return code.substring(with: NSRange(location: wordStart, length: cursor - wordStart + 1)).uppercased()
    }

    private static func opensCommonTableExpressionColumns(_ parenthesis: Int, code: NSString) -> Bool {
        guard let close = matchingClose(of: parenthesis, code: code) else { return false }
        var cursor = close + 1
        guard wordAfter(&cursor, code: code) == "AS" else { return false }
        cursor = skipBlanksForward(from: cursor, code: code)
        guard cursor < code.length else { return false }
        if code.character(at: cursor) == SQLFunctionCallScanner.openParenthesis { return true }
        let next = wordAfter(&cursor, code: code)
        return next == "MATERIALIZED" || next == "NOT"
    }

    private static func matchingClose(of open: Int, code: NSString) -> Int? {
        let close = UInt16(UnicodeScalar(")").value)
        var depth = 0
        var cursor = open
        while cursor < code.length {
            let unit = code.character(at: cursor)
            if unit == SQLFunctionCallScanner.openParenthesis { depth += 1 }
            if unit == close {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    private static func wordAfter(_ cursor: inout Int, code: NSString) -> String? {
        cursor = skipBlanksForward(from: cursor, code: code)
        let start = cursor
        while cursor < code.length, SQLFunctionCallScanner.isIdentifierUnit(code.character(at: cursor)) {
            cursor += 1
        }
        guard cursor > start else { return nil }
        return code.substring(with: NSRange(location: start, length: cursor - start)).uppercased()
    }

    private static func skipBlanksBackward(from index: Int, code: NSString) -> Int {
        var cursor = index
        while cursor >= 0, SQLFunctionCallScanner.isBlank(code.character(at: cursor)) {
            cursor -= 1
        }
        return cursor
    }

    private static func skipBlanksForward(from index: Int, code: NSString) -> Int {
        var cursor = index
        while cursor < code.length, SQLFunctionCallScanner.isBlank(code.character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }
}
