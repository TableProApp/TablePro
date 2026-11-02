//
//  SQLLimitDetector.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// The app's reading of a statement's row limit, in the dialect's own terms. The walk is `SQLStatementRowLimit`'s, which
/// the plugins and the iOS app share.
enum SQLLimitDetector {
    static func hasExplicitRowLimit(
        _ sql: String,
        autoLimitStyle: AutoLimitStyle,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        SQLStatementRowLimit.hasExplicitRowLimit(sql, countsTop: autoLimitStyle == .top, grammar: grammar)
    }

    static func firstRowLimitClauseOffset(_ sql: String, grammar: SQLLexicalGrammar) -> Int? {
        SQLStatementRowLimit.firstRowLimitClauseOffset(sql, grammar: grammar)
    }
}
