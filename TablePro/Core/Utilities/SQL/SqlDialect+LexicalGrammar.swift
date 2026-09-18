//
//  SqlDialect+LexicalGrammar.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

extension SqlDialect {
    /// The grammar the statement scanner has always lexed this dialect with: a backslash keeps every quote open except
    /// on Oracle, and a backtick always quotes.
    var lexicalGrammar: SQLLexicalGrammar {
        var grammar: SQLLexicalGrammar = [.backtickQuotes]
        if self != .oracle {
            grammar.formUnion([
                .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
            ])
        }
        if supportsDollarQuotes { grammar.insert(.taggedDollarQuotes) }
        if supportsHashLineComments { grammar.insert(.hashLineComments) }
        if supportsAlternativeQuoting { grammar.insert(.alternativeQuoting) }
        if endsStatementsAtSlashLines { grammar.insert(.slashLineTerminators) }
        if self == .oracle { grammar.formUnion([.dollarAndHashInIdentifiers, .plsqlBlocks]) }
        return grammar
    }
}

extension SQLStatementScanner {
    static func locatedStatements(in sql: String, dialect: SqlDialect = .generic) -> [LocatedStatement] {
        locatedStatements(in: sql, grammar: dialect.lexicalGrammar)
    }

    static func navigableStatements(in sql: String, dialect: SqlDialect = .generic) -> [LocatedStatement] {
        navigableStatements(in: sql, grammar: dialect.lexicalGrammar)
    }

    static func statementStart(after offset: Int, in sql: String, dialect: SqlDialect = .generic) -> Int? {
        statementStart(after: offset, in: sql, grammar: dialect.lexicalGrammar)
    }

    static func statementSelectionEnd(after offset: Int, in sql: String, dialect: SqlDialect = .generic) -> Int? {
        statementSelectionEnd(after: offset, in: sql, grammar: dialect.lexicalGrammar)
    }

    static func statementStart(before offset: Int, in sql: String, dialect: SqlDialect = .generic) -> Int? {
        statementStart(before: offset, in: sql, grammar: dialect.lexicalGrammar)
    }

    static func allStatements(in sql: String, dialect: SqlDialect = .generic) -> [String] {
        allStatements(in: sql, grammar: dialect.lexicalGrammar)
    }

    static func executableStatements(in sql: String, dialect: SqlDialect = .generic) -> [ExecutableStatement] {
        executableStatements(in: sql, grammar: dialect.lexicalGrammar)
    }

    static func executableText(of text: String, dialect: SqlDialect) -> String {
        executableText(of: text, grammar: dialect.lexicalGrammar)
    }

    static func allStatementsPreservingSemicolons(in sql: String) -> [String] {
        allStatementsPreservingSemicolons(in: sql, grammar: SqlDialect.generic.lexicalGrammar)
    }

    static func statementAtCursor(in sql: String, cursorPosition: Int, dialect: SqlDialect = .generic) -> String {
        statementAtCursor(in: sql, cursorPosition: cursorPosition, grammar: dialect.lexicalGrammar)
    }

    static func locatedStatementAtCursor(
        in sql: String,
        cursorPosition: Int,
        dialect: SqlDialect = .generic
    ) -> LocatedStatement {
        locatedStatementAtCursor(in: sql, cursorPosition: cursorPosition, grammar: dialect.lexicalGrammar)
    }
}

extension SqlLexer {
    static func skipQuotedString(
        _ text: NSString,
        from offset: Int,
        quote: UInt16,
        length: Int,
        dialect: SqlDialect
    ) -> Span {
        skipQuotedString(
            text,
            from: offset,
            quote: quote,
            length: length,
            backslashEscapes: dialect.requiresBackslashEscapesInSingleQuotes
        )
    }
}

extension SqlBlockStructure {
    static func readKeyword(
        _ text: NSString,
        at offset: Int,
        length: Int,
        dialect: SqlDialect
    ) -> (text: String, end: Int) {
        readKeyword(text, at: offset, length: length, grammar: dialect.lexicalGrammar)
    }

    static func startsWord(_ text: NSString, at offset: Int, length: Int, dialect: SqlDialect) -> Bool {
        startsWord(text, at: offset, length: length, grammar: dialect.lexicalGrammar)
    }

    static func continuesWord(_ character: UInt16, dialect: SqlDialect) -> Bool {
        continuesWord(character, grammar: dialect.lexicalGrammar)
    }
}

extension SQLStatementBoundaries {
    static func makeTracker(for dialect: SqlDialect) -> any SQLStatementBoundaryTracking {
        makeTracker(for: dialect.lexicalGrammar)
    }
}
