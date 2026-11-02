//
//  CompareRowFilter.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

internal enum CompareRowFilter {
    // The filter is wrapped in parentheses and run on the source and the target, so it has to read as one closed
    // condition however either engine reads a quote, a bracket or a backslash.
    private static let readings: [SQLLexicalGrammar] = {
        let quotes: SQLLexicalGrammar = [.backtickQuotes, .bracketQuotedIdentifiers]
        let backslash: SQLLexicalGrammar = [
            .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        ]
        return [quotes, quotes.union(backslash)].flatMap { [$0, $0.union(.doubledClosingBracketEscapes)] }
    }()

    internal static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // `databaseTypes` adds the readings of the engines the filter runs on. T-SQL's need for one parenthesised group is
    // left out: the wrapper is that group.
    internal static func validationError(for text: String, databaseTypes: [DatabaseType] = []) -> String? {
        guard let filter = normalized(text) else { return nil }
        // By scalar, wherever they sit: a `;` or `-` a combining mark follows is one Character, so `--` then U+0301
        // passed and commented out the ORDER BY and the row limit after it.
        let scalars = Array(filter.unicodeScalars)
        guard !scalars.contains(";") else {
            return String(localized: "A filter is a single condition and cannot contain a semicolon.")
        }
        // `SQLBoundaryValidator` anchors `--` to the start or to whitespace. `#` is MySQL's line comment.
        let hasDoubleDash = zip(scalars, scalars.dropFirst()).contains { $0 == "-" && $1 == "-" }
        guard !hasDoubleDash, !scalars.contains("#"), SQLBoundaryValidator.isRawFilterConditionSafe(filter) else {
            return String(localized: "A filter cannot contain a comment.")
        }
        let engineReadings = databaseTypes.flatMap { $0.lexicalReadings.all }.map { $0.subtracting(.unterminatedStatements) }
        guard SQLExpressionFragment.isSingleExpression(filter, readings: readings + engineReadings) else {
            return String(localized: "A quote or parenthesis in this filter is not closed.")
        }
        return nil
    }

    internal static func condition(for filter: String) -> String {
        "(\(filter))"
    }
}
