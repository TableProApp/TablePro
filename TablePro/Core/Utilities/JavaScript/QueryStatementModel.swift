//
//  QueryStatementModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// How a query language divides a document into statements.
///
/// Curated per database type rather than read from `DriverPlugin`, for the reason
/// `PluginMetadataRegistry.buildMetadataSnapshot` records: a static read off a plugin built before
/// that static existed crashes with `EXC_BAD_INSTRUCTION` on a missing witness table entry. Keeping
/// it app-side also means an already-installed MongoDB plugin gets the right splitting with no
/// re-release.
///
/// `editorLanguage` cannot answer this question. Elasticsearch also highlights as JavaScript, but
/// its Query DSL is a verb line followed by a JSON body and is not JavaScript at all.
enum QueryStatementModel {
    /// Statements end at a semicolon, and a semicolon inside a string or a comment does not count.
    case sql

    /// Statements are the top-level statements of a JavaScript program.
    case javascript

    static func forDatabaseType(_ type: DatabaseType) -> QueryStatementModel {
        switch type {
        case .mongodb: return .javascript
        default: return .sql
        }
    }
}

/// Splits a query document the way its language does.
///
/// One entry point for both models so no caller has to branch, returning the same statement types
/// the SQL scanner has always returned.
enum QueryStatementScanner {
    static func locatedStatements(
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> [SQLStatementScanner.LocatedStatement] {
        switch model {
        case .sql:
            return SQLStatementScanner.locatedStatements(in: text, grammar: grammar)
        case .javascript:
            return JavaScriptStatementScanner.locatedStatements(in: text).map(located)
        }
    }

    static func navigableStatements(
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> [SQLStatementScanner.LocatedStatement] {
        switch model {
        case .sql:
            return SQLStatementScanner.navigableStatements(in: text, grammar: grammar)
        case .javascript:
            return JavaScriptStatementScanner.executableStatements(in: text)
                .map(located)
                .filter { $0.contentRange.length > 0 }
        }
    }

    static func executableStatements(
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> [SQLStatementScanner.ExecutableStatement] {
        switch model {
        case .sql:
            return SQLStatementScanner.executableStatements(in: text, grammar: grammar)
        case .javascript:
            return JavaScriptStatementScanner.executableStatements(in: text).compactMap { statement in
                let located = located(statement)
                guard located.contentRange.length > 0 else { return nil }
                return SQLStatementScanner.ExecutableStatement(
                    sql: (text as NSString).substring(with: located.contentRange),
                    range: located.contentRange
                )
            }
        }
    }

    static func locatedStatementAtCursor(
        in text: String,
        cursorPosition: Int,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> SQLStatementScanner.LocatedStatement {
        switch model {
        case .sql:
            return SQLStatementScanner.locatedStatementAtCursor(
                in: text, cursorPosition: cursorPosition, grammar: grammar
            )
        case .javascript:
            guard let statement = JavaScriptStatementScanner.statementAtCursor(
                in: text, cursorPosition: cursorPosition
            ) else {
                return SQLStatementScanner.LocatedStatement(sql: "", offset: 0, hasContent: false)
            }
            return located(statement)
        }
    }

    static func statementStart(
        after offset: Int,
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        switch model {
        case .sql:
            return SQLStatementScanner.statementStart(after: offset, in: text, grammar: grammar)
        case .javascript:
            return navigableStatements(in: text, model: model, grammar: grammar)
                .first { $0.contentRange.location > offset }?
                .contentRange.location
        }
    }

    static func statementStart(
        before offset: Int,
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        switch model {
        case .sql:
            return SQLStatementScanner.statementStart(before: offset, in: text, grammar: grammar)
        case .javascript:
            return navigableStatements(in: text, model: model, grammar: grammar)
                .last { $0.contentRange.location < offset }?
                .contentRange.location
        }
    }

    static func statementSelectionEnd(
        after offset: Int,
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        switch model {
        case .sql:
            return SQLStatementScanner.statementSelectionEnd(after: offset, in: text, grammar: grammar)
        case .javascript:
            if let next = statementStart(after: offset, in: text, model: model, grammar: grammar) { return next }
            let end = navigableStatements(in: text, model: model, grammar: grammar).last?.contentRange.upperBound
            return end.flatMap { $0 > offset ? $0 : nil }
        }
    }

    private static func located(
        _ statement: JavaScriptStatementScanner.Statement
    ) -> SQLStatementScanner.LocatedStatement {
        SQLStatementScanner.LocatedStatement(
            sql: statement.text,
            offset: statement.range.location,
            hasContent: statement.hasContent
        )
    }
}
