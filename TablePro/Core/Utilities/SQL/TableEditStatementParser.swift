//
//  TableEditStatementParser.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

/// One dot-separated part of a name, as the statement wrote it.
struct SQLNamePart: Equatable, Sendable {
    let text: String
    let isQuoted: Bool
}

struct SQLObjectName: Equatable, Sendable {
    let parts: [SQLNamePart]
}

struct SQLRenamePair: Equatable, Sendable {
    let from: SQLObjectName
    let to: SQLObjectName
}

/// What one statement means for the tables the app keeps settings about, and for the transaction
/// and the name context of the statements after it.
enum TableEditStatement: Equatable, Sendable {
    case drop([SQLObjectName], kind: TableInfo.TableType)
    case rename([SQLRenamePair], kind: TableInfo.TableType)
    case beginsTransaction
    case commits
    case rollsBack
    case rollsBackToSavepoint
    /// `SET IMPLICIT_TRANSACTIONS`, `PREPARE TRANSACTION`, `COMMIT AND CHAIN`: the transaction
    /// state after it is no longer something the text shows.
    case losesTransactionTracking
    /// `USE`, with the name it moved to, or nil when that name could not be read.
    case selectsDatabase(SQLObjectName?)
    case losesSchemaContext
    case createsTemporaryTable(SQLObjectName)
    /// A procedure, a prepared statement or an anonymous block: code the server runs that the text
    /// does not show, and that can create a temporary table or move the schema.
    case runsUnseenCode
    /// T-SQL's `IF`, `ELSE`, `WHILE`, `GOTO`, `RETURN`, a label, or a `TRY...CATCH` block. SQL Server
    /// runs a batch whole, so the statements after one of these may have been skipped, or may have
    /// failed into a `CATCH` without the batch failing.
    case controlsFlow
    case other

    var editsTable: Bool {
        switch self {
        case .drop, .rename:
            return true
        case .beginsTransaction, .commits, .rollsBack, .rollsBackToSavepoint, .losesTransactionTracking,
             .selectsDatabase, .losesSchemaContext, .createsTemporaryTable, .runsUnseenCode, .controlsFlow, .other:
            return false
        }
    }

    /// Whether this can leave the session resolving a bare name somewhere other than the scope a
    /// tab records, for this run and every later one.
    var changesNameHazards: Bool {
        switch self {
        case .createsTemporaryTable, .losesSchemaContext, .runsUnseenCode:
            return true
        case .drop, .rename, .beginsTransaction, .commits, .rollsBack, .rollsBackToSavepoint,
             .losesTransactionTracking, .selectsDatabase, .controlsFlow, .other:
            return false
        }
    }
}

/// Reads the statements that drop or rename a table, and the ones that decide whether such an
/// edit is committed and where a bare name points.
///
/// A statement is read only when it is exactly one of those forms. Anything left over, such as a
/// column rename, a clause this does not know, or a second command SQL Server runs without a `;`,
/// makes the whole statement `.other`, because a partial reading is a guess.
enum TableEditStatementParser {
    /// MySQL skips the body of a `/*!NNNNN ... */` comment on a server older than `NNNNN` and still
    /// answers success, so a drop or rename written inside one is not read. What such a comment
    /// may create still counts as a hazard, since counting one that never ran only skips more.
    static func parse(_ sql: String, dialect: TableEditDialect, grammar: SQLLexicalGrammar) -> TableEditStatement {
        let statement = read(sql, dialect: dialect, grammar: grammar)
        guard statement.editsTable, grammar.contains(.executableComments),
              sql.contains("/*!") || sql.contains("/*M!") else { return statement }
        return .other
    }

    private static let controlFlowKeywords: Set<String> = ["IF", "ELSE", "WHILE", "BREAK", "CONTINUE", "GOTO", "RETURN"]

    private static func read(_ sql: String, dialect: TableEditDialect, grammar: SQLLexicalGrammar) -> TableEditStatement {
        var reader = Reader(SQLTokenCursor(sql, grammar: grammar))
        guard let keyword = reader.nextWord() else { return .other }
        if dialect.branchesInsideBatches, controlFlowKeywords.contains(keyword) || reader.startsLabel() {
            return .controlsFlow
        }
        switch keyword {
        case "DROP":
            return reader.drop()
        case "ALTER":
            return reader.alter(dialect: dialect)
        case "RENAME":
            return reader.renameTables()
        case "BEGIN":
            if grammar.contains(.plsqlBlocks) || reader.opensCompoundStatement() { return .runsUnseenCode }
            if dialect.branchesInsideBatches, reader.namesTryOrCatchBlock() { return .controlsFlow }
            return SqlBlockStructure.beginStartsTransaction(followedBy: reader.peekWord()) ? .beginsTransaction : .other
        case "DECLARE":
            return grammar.contains(.plsqlBlocks) ? .runsUnseenCode : .other
        case "CALL", "DO":
            return .runsUnseenCode
        case "START":
            return reader.accept("TRANSACTION") ? .beginsTransaction : .other
        case "SAVEPOINT":
            return .beginsTransaction
        case "SAVE":
            return reader.accept("TRAN") || reader.accept("TRANSACTION") ? .beginsTransaction : .other
        case "COMMIT":
            return reader.commit()
        case "RELEASE":
            return .commits
        case "END":
            if dialect.branchesInsideBatches, reader.namesTryOrCatchBlock() { return .controlsFlow }
            return dialect.endCommits ? reader.commit() : .other
        case "ROLLBACK", "ABORT":
            return reader.rollback()
        case "PREPARE":
            return reader.accept("TRANSACTION") ? .losesTransactionTracking : .other
        case "SET":
            return reader.set()
        case "RESET":
            return reader.accept("SEARCH_PATH") || reader.accept("ALL") ? .losesSchemaContext : .other
        case "DISCARD":
            return reader.accept("ALL") ? .losesSchemaContext : .other
        case "USE":
            return reader.use()
        case "EXEC", "EXECUTE":
            return reader.accept("AS") ? .losesSchemaContext : reader.storedProcedureCall(grammar: grammar)
        case "REVERT", "SETUSER":
            return .losesSchemaContext
        case "CREATE":
            return reader.createTemporaryTable(dialect: dialect)
        default:
            return .other
        }
    }
}

private struct Reader {
    private static let dropOptions: Set<String> = ["CASCADE", "RESTRICT", "CONSTRAINTS", "PURGE", "SYNC", "NO", "DELAY"]
    private static let transactionNouns: Set<String> = ["WORK", "TRANSACTION", "TRAN"]
    private static let schemaSettings: Set<String> = ["SEARCH_PATH", "SCHEMA", "CURRENT_SCHEMA"]
    private static let commitModeSettings: Set<String> = ["IMPLICIT_TRANSACTIONS", "ANSI_DEFAULTS", "AUTOCOMMIT"]

    private var cursor: SQLTokenCursor

    init(_ cursor: SQLTokenCursor) {
        self.cursor = cursor
    }

    mutating func nextWord() -> String? {
        cursor.next()?.word
    }

    func peekWord() -> String? {
        cursor.peek()?.word
    }

    mutating func accept(_ word: String) -> Bool {
        guard peekWord() == word else { return false }
        _ = cursor.next()
        return true
    }

    private mutating func acceptSymbol(_ symbol: UInt16) -> Bool {
        guard cursor.peek()?.isSymbol(symbol) == true else { return false }
        _ = cursor.next()
        return true
    }

    private var isAtEnd: Bool {
        cursor.peek() == nil
    }

    mutating func name() -> SQLObjectName? {
        var parts: [SQLNamePart] = []
        repeat {
            switch cursor.next() {
            case .word:
                parts.append(SQLNamePart(text: cursor.lastTokenText, isQuoted: false))
            case .quotedIdentifier(let body):
                parts.append(SQLNamePart(text: body, isQuoted: true))
            case .literal, .symbol, nil:
                return nil
            }
        } while acceptSymbol(SQLTokenCursor.period)
        return SQLObjectName(parts: parts)
    }

    // MARK: - Drop and rename

    private mutating func objectKind() -> TableInfo.TableType? {
        switch nextWord() {
        case "TABLE":
            return .table
        case "VIEW":
            return .view
        case "MATERIALIZED":
            return accept("VIEW") ? .materializedView : nil
        case "FOREIGN":
            return accept("TABLE") ? .foreignTable : nil
        default:
            return nil
        }
    }

    private mutating func acceptIfExists() {
        var lookahead = self
        guard lookahead.accept("IF"), lookahead.accept("EXISTS") else { return }
        self = lookahead
    }

    /// `DROP TEMPORARY TABLE` never reaches a table the app lists.
    mutating func drop() -> TableEditStatement {
        guard let kind = objectKind() else { return .other }
        acceptIfExists()
        guard let names = names() else { return .other }
        while let token = cursor.next() {
            guard let word = token.word else { return .other }
            if Self.dropOptions.contains(word) { continue }
            guard word == "ON", acceptOnClusterTail() else { return .other }
        }
        return .drop(names, kind: kind)
    }

    private mutating func names() -> [SQLObjectName]? {
        var names: [SQLObjectName] = []
        repeat {
            guard let name = name() else { return nil }
            names.append(name)
        } while acceptSymbol(SQLTokenCursor.comma)
        return names
    }

    /// ClickHouse's `ON CLUSTER name`, with `ON` already read.
    private mutating func acceptOnClusterTail() -> Bool {
        accept("CLUSTER") && name() != nil
    }

    mutating func alter(dialect: TableEditDialect) -> TableEditStatement {
        if accept("SESSION") {
            return accept("SET") && accept("CURRENT_SCHEMA") ? .losesSchemaContext : .other
        }
        guard let kind = objectKind() else { return .other }
        /// `ALTER TABLE IF EXISTS missing RENAME TO live` succeeds having renamed nothing, and read
        /// as a rename it would move stale settings over the live table's own.
        var conditional = self
        if conditional.accept("IF"), conditional.accept("EXISTS") { return .other }
        guard let source = name(), accept("RENAME") else { return .other }
        let namedTarget = accept("TO") || accept("AS")
        guard namedTarget || dialect.renamesWithoutTo, let target = name(), isAtEnd else { return .other }
        return .rename([SQLRenamePair(from: source, to: target)], kind: kind)
    }

    /// MySQL's and ClickHouse's `RENAME TABLE a TO b, c TO d`, applied pair by pair in order.
    mutating func renameTables() -> TableEditStatement {
        guard accept("TABLE") || accept("TABLES") else { return .other }
        var pairs: [SQLRenamePair] = []
        repeat {
            guard let source = name(), accept("TO"), let target = name() else { return .other }
            pairs.append(SQLRenamePair(from: source, to: target))
        } while acceptSymbol(SQLTokenCursor.comma)
        if accept("ON"), !acceptOnClusterTail() { return .other }
        return isAtEnd ? .rename(pairs, kind: .table) : .other
    }

    /// `CREATE TEMPORARY TABLE people`, or SQLite's `CREATE TABLE temp.people` and
    /// `CREATE VIRTUAL TABLE temp.people USING fts5(...)`, shadows the real `people` for the rest of
    /// the session, so a bare `DROP TABLE people` after it drops the temporary one.
    mutating func createTemporaryTable(dialect: TableEditDialect) -> TableEditStatement {
        if accept("OR"), !accept("REPLACE") { return .other }
        _ = accept("GLOBAL") || accept("LOCAL") || accept("PRIVATE")
        let saysTemporary = accept("TEMPORARY") || accept("TEMP")
        _ = accept("VIRTUAL")
        guard accept("TABLE") || accept("VIEW") else { return .other }
        var lookahead = self
        if lookahead.accept("IF"), lookahead.accept("NOT"), lookahead.accept("EXISTS") {
            self = lookahead
        }
        guard let name = name() else { return .other }
        let inTemporaryContainer = name.parts.dropLast().contains { dialect.namesTemporaryContainer($0.text) }
        return saysTemporary || inTemporaryContainer ? .createsTemporaryTable(name) : .other
    }

    /// `done:` before a statement, which a T-SQL `GOTO` can jump to or over.
    func startsLabel() -> Bool {
        cursor.peek()?.isSymbol(SQLTokenCursor.colon) == true
    }

    func namesTryOrCatchBlock() -> Bool {
        peekWord() == "TRY" || peekWord() == "CATCH"
    }

    /// MariaDB's `BEGIN NOT ATOMIC ... END` runs a compound statement, not a transaction.
    mutating func opensCompoundStatement() -> Bool {
        var lookahead = self
        return lookahead.accept("NOT") && lookahead.accept("ATOMIC")
    }

    /// A procedure call, which is unseen code, unless it is SQL Server's only table rename,
    /// `EXEC sp_rename 'schema.old', 'new'`, optionally typed `'OBJECT'`. The old name is itself a
    /// multipart name inside a string. The new one is taken exactly as written, because the
    /// procedure names the object with the literal text.
    mutating func storedProcedureCall(grammar: SQLLexicalGrammar) -> TableEditStatement {
        guard let procedure = name(), Self.isRenameProcedure(procedure) else { return .runsUnseenCode }
        guard let source = stringLiteral().flatMap({ Self.multipartName(in: $0, grammar: grammar) }),
              acceptSymbol(SQLTokenCursor.comma),
              let target = stringLiteral(), !target.isEmpty else { return .other }
        if acceptSymbol(SQLTokenCursor.comma) {
            guard stringLiteral()?.uppercased() == "OBJECT" else { return .other }
        }
        guard isAtEnd else { return .other }
        let renamed = SQLObjectName(parts: [SQLNamePart(text: target, isQuoted: true)])
        return .rename([SQLRenamePair(from: source, to: renamed)], kind: .table)
    }

    private static func isRenameProcedure(_ name: SQLObjectName) -> Bool {
        let parts = name.parts.map { $0.text.lowercased() }
        return parts == ["sp_rename"] || parts == ["sys", "sp_rename"]
    }

    private static func multipartName(in text: String, grammar: SQLLexicalGrammar) -> SQLObjectName? {
        var reader = Reader(SQLTokenCursor(text, grammar: grammar))
        guard let name = reader.name(), reader.isAtEnd else { return nil }
        return name
    }

    /// A `'...'` or `N'...'` literal's text, with doubled quotes undone.
    private mutating func stringLiteral() -> String? {
        if peekWord() == "N" {
            var lookahead = self
            _ = lookahead.cursor.next()
            if case .literal = lookahead.cursor.peek() { self = lookahead }
        }
        guard case .literal = cursor.next() else { return nil }
        var text = cursor.lastTokenText
        if text.first == "N" || text.first == "n" { text.removeFirst() }
        guard text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") else { return nil }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }

    // MARK: - Transactions and context

    mutating func commit() -> TableEditStatement {
        guard !accept("PREPARED") else { return .other }
        _ = acceptTransactionNoun()
        return chains() ? .losesTransactionTracking : .commits
    }

    /// T-SQL's `ROLLBACK TRAN name` may name the transaction or a savepoint inside it, and only
    /// the savepoint leaves the transaction open, so a named rollback is read as the savepoint.
    mutating func rollback() -> TableEditStatement {
        guard !accept("PREPARED") else { return .other }
        _ = acceptTransactionNoun()
        if chains() { return .losesTransactionTracking }
        guard let next = cursor.peek() else { return .rollsBack }
        if next.word == "AND" { return .rollsBack }
        return .rollsBackToSavepoint
    }

    private mutating func acceptTransactionNoun() -> Bool {
        guard let word = peekWord(), Self.transactionNouns.contains(word) else { return false }
        _ = cursor.next()
        return true
    }

    /// `AND CHAIN` opens the next transaction the moment this one ends. `AND NO CHAIN` does not.
    private mutating func chains() -> Bool {
        var lookahead = self
        guard lookahead.accept("AND") else { return false }
        return !lookahead.accept("NO")
    }

    mutating func set() -> TableEditStatement {
        _ = accept("SESSION") || accept("LOCAL") || accept("GLOBAL")
        guard let first = nextWord() else { return .other }
        if Self.schemaSettings.contains(first) { return .losesSchemaContext }
        var word: String? = first
        while let current = word {
            if Self.commitModeSettings.contains(current) { return .losesTransactionTracking }
            word = nextIdentifier()
        }
        return .other
    }

    private mutating func nextIdentifier() -> String? {
        while let token = cursor.next() {
            if let identifier = token.identifier { return identifier }
        }
        return nil
    }

    mutating func use() -> TableEditStatement {
        guard let name = name(), isAtEnd else { return .selectsDatabase(nil) }
        return .selectsDatabase(name)
    }
}
