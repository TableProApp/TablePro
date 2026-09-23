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
        let source = sql as NSString
        let code = SQLCodeProjection.code(of: sql, grammar: grammar, revealingExecutableComments: true) as NSString
        var index = 0
        while index < code.length {
            defer { index += 1 }
            guard code.character(at: index) == openParenthesis else { continue }
            switch callee(before: index, code: code, source: source) {
            case .none:
                continue
            case .unnamed:
                return false
            case .named(let name):
                guard isBuiltinOrSyntax(name) else { return false }
            }
        }
        return true
    }

    static func isBuiltinOrSyntax(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return SQLiteBuiltinNames.functions.contains(lowered)
            || SQLiteBuiltinNames.tableValuedFunctions.contains(lowered)
            || SQLiteBuiltinNames.keywords.contains(lowered)
            || lowered.hasPrefix("pragma_")
    }

    private enum Callee {
        case none
        case unnamed
        case named(String)
    }

    private static let openParenthesis = UInt16(UnicodeScalar("(").value)
    private static let quoteClosers: Set<UInt16> = [0x22, 0x60, 0x5D]

    /// What stands in front of the parenthesis at `index`. The projection has blanked comments,
    /// literals and quoted identifiers to spaces, so the source text over that blank stretch says
    /// whether a quoted name was there.
    private static func callee(before index: Int, code: NSString, source: NSString) -> Callee {
        var cursor = index - 1
        while cursor >= 0, isBlank(code.character(at: cursor)) {
            cursor -= 1
        }
        let blankStart = cursor + 1
        if blankStart < index {
            let skipped = source.substring(with: NSRange(location: blankStart, length: index - blankStart))
            if skipped.utf16.contains(where: quoteClosers.contains) {
                return quotedName(in: skipped).map(Callee.named) ?? .unnamed
            }
        }
        guard cursor >= 0 else { return .none }
        if quoteClosers.contains(code.character(at: cursor)) {
            return quotedName(endingAt: cursor, in: code).map(Callee.named) ?? .unnamed
        }
        guard isIdentifierUnit(code.character(at: cursor)) else { return .none }
        var start = cursor
        while start > 0, isIdentifierUnit(code.character(at: start - 1)) {
            start -= 1
        }
        return .named(code.substring(with: NSRange(location: start, length: cursor - start + 1)))
    }

    /// The name inside the one quoted identifier a stretch holds, and nothing else but blanks and
    /// comments around it. Anything less certain is left unnamed.
    private static func quotedName(in stretch: String) -> String? {
        let trimmed = stretch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last, trimmed.count >= 2 else { return nil }
        let pairs: [Character: Character] = ["\"": "\"", "`": "`", "[": "]"]
        guard pairs[first] == last else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        let unescaped = first == "[" ? inner : inner.replacingOccurrences(of: "\(last)\(last)", with: "\(last)")
        guard !unescaped.contains(last) || first == "[" else { return nil }
        return unescaped
    }

    /// A quoted name a reading left as code, which happens for `[name]` under a grammar without
    /// bracket quoting.
    private static func quotedName(endingAt closer: Int, in code: NSString) -> String? {
        let closing = code.character(at: closer)
        let opening = closing == 0x5D ? UInt16(UnicodeScalar("[").value) : closing
        var cursor = closer - 1
        while cursor >= 0, code.character(at: cursor) != opening {
            cursor -= 1
        }
        guard cursor >= 0 else { return nil }
        return quotedName(in: code.substring(with: NSRange(location: cursor, length: closer - cursor + 1)))
    }

    private static func isBlank(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x0C || unit == 0x0B
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) || unit > 0x7F
    }
}
