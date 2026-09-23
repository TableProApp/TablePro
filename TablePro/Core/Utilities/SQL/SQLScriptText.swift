//
//  SQLScriptText.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// The one owner of how SQL text meets an engine: what each statement is sent as, and how a list of statements is
/// written into a script that engine's own client runs.
///
/// The two are different texts, and one string serving as both is how a saved sync script came to run only its first
/// `DROP`. A driver takes one statement per call with no separator after it, and on Oracle the `;` after a unit's
/// `END` belongs to the unit while the one after a `CALL` trigger body stores the trigger INVALID. A script client
/// needs every statement ended its own way: SQL*Plus reads a PL/SQL unit until a line holding only `/`, the mysql
/// client ends a statement at its first `;` unless a `DELIMITER` block moves the delimiter, and SQL Server's tools
/// need a routine, a view or a trigger alone in its batch.
///
/// Text is divided into statements only where the app tracks the engine's grammar: Oracle, MySQL, PostgreSQL and
/// SQLite. Every other engine's text is sent whole, as it always was, because the generic grammar cuts a T-SQL body
/// with no `BEGIN`, a Dameng declaration section and a Snowflake `$$` body into pieces the server rejects.
internal struct SQLScriptText {
    private static let batchSeparatedEngines: Set<DatabaseType> = [.mssql]
    private static let mysqlScriptDelimiter = "//"

    internal let databaseType: DatabaseType
    private let dialect: SqlDialect
    private let grammar: SQLLexicalGrammar

    internal init(databaseType: DatabaseType) {
        self.databaseType = databaseType
        self.dialect = SqlDialect.from(databaseTypeId: databaseType.rawValue)
        self.grammar = databaseType.lexicalGrammar
    }

    /// The statements `text` holds, each exactly as the driver receives it in one call, in order.
    internal func sendableStatements(_ text: String) -> [String] {
        guard tracksGrammar else {
            let whole = StatementBlank.trimming(text)
            return whole.isEmpty ? [] : [whole]
        }
        return SQLStatementScanner.executableStatements(in: text, grammar: grammar).map(\.sql)
    }

    /// The text that decides whether two definitions create the same object.
    ///
    /// Where the grammar is tracked that is the text that would run, which keeps a unit's own `;`, because Oracle
    /// stores a procedure sent without it INVALID and one sent with it VALID. An engine whose grammar is not tracked
    /// accepts a definition with or without a trailing `;`, so a difference in it is not one there.
    internal func comparableText(_ definition: String) -> String {
        guard tracksGrammar else {
            var text = StatementBlank.trimming(definition)
            while text.hasSuffix(";") {
                text = StatementBlank.trimming(String(text.dropLast()))
            }
            return text
        }
        return sendableStatements(definition).joined(separator: ";\n")
    }

    internal func leadingKeyword(of statement: String) -> String? {
        let text = statement as NSString
        let length = text.length
        var index = 0
        while index < length {
            let blank = StatementBlank.blankLength(in: text, at: index)
            guard blank == 0 else {
                index += blank
                continue
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), span.kind.isComment else {
                let head = text.substring(with: NSRange(location: index, length: min(length - index, 64)))
                return String(head.prefix { $0.isLetter }).uppercased()
            }
            index = max(span.end, index + 1)
        }
        return nil
    }

    /// Every statement in `statements`, which are sendable texts, written as one script for this engine's client.
    internal func script(_ statements: [String]) -> String {
        let ended = statements
            .map { StatementBlank.trimming($0) }
            .filter { !$0.isEmpty }
            .map(terminated)
        guard Self.batchSeparatedEngines.contains(databaseType) else {
            return ended.joined(separator: "\n")
        }
        return ended.map { "\($0)\nGO" }.joined(separator: "\n")
    }

    /// `ddl`, text a driver produced that may hold several statements, as script text for this engine's client.
    internal func scriptText(forDriverText ddl: String) -> String {
        sendableStatements(ddl).map(terminated).joined(separator: "\n")
    }

    // MARK: - Terminators

    private var tracksGrammar: Bool {
        switch dialect {
        case .oracle, .mysql, .postgres, .sqlite:
            return true
        default:
            return false
        }
    }

    /// Whether the engine's client reads a unit until a line holding only `/`. SQL*Plus does, and so does Dameng's
    /// DISQL: measured on DM8, a script ending a procedure with `END;` ran the statement before it and then reported
    /// "The script file is not complete" without running anything after it.
    private var endsUnitsWithSlashLines: Bool {
        dialect == .oracle || Self.slashLineClientEngines.contains(databaseType)
    }

    private static let slashLineClientEngines: Set<DatabaseType> = [.dameng]

    /// One sendable statement, ended the way this engine's client ends it.
    private func terminated(_ statement: String) -> String {
        if endsUnitsWithSlashLines {
            return runsAsPLSQLUnit(statement) ? "\(statement)\n/" : endedBySemicolon(statement)
        }
        if dialect == .mysql, holdsInnerSemicolon(statement) {
            return delimiterBlock(statement)
        }
        return endedBySemicolon(statement)
    }

    /// Whether the client reads `statement` in PL/SQL mode, where only a `/` line runs it.
    ///
    /// A definition takes no bind parameters and a block keeps its own `;`, and between them they are every
    /// statement SQL*Plus buffers: a stored unit including a `CALL` trigger, `CREATE JAVA`, and an anonymous block. A
    /// `CALL` trigger is the case a `;` cannot end, because Oracle stores it INVALID with one. The kind is read from
    /// the statement's first words, which Dameng spells the way Oracle does.
    private func runsAsPLSQLUnit(_ statement: String) -> Bool {
        guard let located = SQLStatementScanner.executableStatements(in: statement, grammar: DatabaseType.oracle.lexicalGrammar).first else {
            return false
        }
        return !located.acceptsBindParameters || located.sql.hasSuffix(";")
    }

    /// Whether the mysql client would end `statement` early: it ends a statement at the first `;` it meets outside a
    /// string or a comment, so a routine body needs another delimiter. A trailing `;` ends the statement where it
    /// ends anyway.
    private func holdsInnerSemicolon(_ statement: String) -> Bool {
        var body = statement
        while body.hasSuffix(";") {
            body = StatementBlank.trimming(String(body.dropLast()))
        }
        return codeShape(of: body).holdsSemicolon
    }

    /// `DELIMITER //`, which the mysql client and TablePro's own import both honour, rather than mysqldump's `;;`:
    /// the import reads `DELIMITER ;;` as a statement ended by its own first `;`.
    private func delimiterBlock(_ statement: String) -> String {
        let delimiter = Self.mysqlScriptDelimiter
        let body = codeShape(of: statement).endsInLineComment
            ? "\(statement)\n\(delimiter)"
            : "\(statement) \(delimiter)"
        return "DELIMITER \(delimiter)\n\(body)\nDELIMITER ;"
    }

    /// A terminator written after a line comment would be part of the comment, so it goes on a line of its own.
    private func endedBySemicolon(_ statement: String) -> String {
        guard !statement.hasSuffix(";") else { return statement }
        return codeShape(of: statement).endsInLineComment ? "\(statement)\n;" : "\(statement);"
    }

    private struct CodeShape {
        var holdsSemicolon = false
        var endsInLineComment = false
    }

    /// Walks the code of `statement` with the lexer every scanner shares, stepping over strings, quoted identifiers
    /// and comments.
    private func codeShape(of statement: String) -> CodeShape {
        let text = statement as NSString
        let length = text.length
        var shape = CodeShape()
        var index = 0
        while index < length {
            if let end = SQLNonCodeSpan.end(at: index, in: text, grammar: grammar) {
                if end >= length, startsLineComment(text, at: index, length: length) {
                    shape.endsInLineComment = true
                }
                index = max(end, index + 1)
                continue
            }
            if text.character(at: index) == SqlLexer.semicolon {
                shape.holdsSemicolon = true
            }
            index += 1
        }
        return shape
    }

    private func startsLineComment(_ text: NSString, at index: Int, length: Int) -> Bool {
        SqlLexer.startsLineComment(text, at: index, length: length)
            || (grammar.contains(.hashLineComments) && text.character(at: index) == SqlLexer.hash)
    }
}
