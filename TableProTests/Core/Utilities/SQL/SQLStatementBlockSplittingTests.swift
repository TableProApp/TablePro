//
//  SQLStatementBlockSplittingTests.swift
//  TableProTests
//
//  A semicolon inside a routine body separates the statements in the body, not the routine from what follows it.
//  Splitting there sent a fragment of a trigger to the driver, and once the gutter draws a run control per statement
//  it offers to send that fragment on its own.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL statement scanner - block splitting")
struct SQLStatementBlockSplittingTests {

    // MARK: - Routine bodies

    @Test("A SQLite trigger body stays one statement")
    func sqliteTriggerBody() {
        let sql = """
        CREATE TRIGGER t AFTER INSERT ON a BEGIN
          UPDATE b SET x = 1;
          DELETE FROM c;
        END;
        SELECT 1;
        """
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .sqlite)
        #expect(statements.count == 2)
        #expect(statements.first?.hasPrefix("CREATE TRIGGER") == true)
        #expect(statements.first?.hasSuffix("END") == true)
        #expect(statements.last == "SELECT 1")
    }

    @Test("A MySQL procedure body stays one statement")
    func mysqlProcedureBody() {
        let sql = """
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
          SELECT 2;
        END;
        SELECT 3;
        """
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .mysql)
        #expect(statements.count == 2)
        #expect(statements.last == "SELECT 3")
    }

    @Test("Nested BEGIN blocks close in order")
    func nestedBlocks() {
        let sql = """
        CREATE PROCEDURE p()
        BEGIN
          BEGIN
            SELECT 1;
          END;
          SELECT 2;
        END;
        SELECT 3;
        """
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .mysql)
        #expect(statements.count == 2)
        #expect(statements.last == "SELECT 3")
    }

    @Test("END IF does not close the routine body")
    func controlFlowEndDoesNotClose() {
        let sql = """
        CREATE PROCEDURE p()
        BEGIN
          IF x THEN
            SELECT 1;
          END IF;
          SELECT 2;
        END;
        SELECT 3;
        """
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .mysql)
        #expect(statements.count == 2)
        #expect(statements.last == "SELECT 3")
    }

    @Test("A CASE expression balances its own END")
    func caseExpressionBalances() {
        let sql = "SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t;\nSELECT 2;"
        #expect(
            SQLStatementScanner.allStatements(in: sql) == [
                "SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t",
                "SELECT 2",
            ]
        )
    }

    // MARK: - Transactions

    /// `BEGIN;` opens a transaction, not a block. Reading it as a block swallows every statement after it, which is
    /// the worst thing block tracking can do to a script.
    @Test("BEGIN; is a transaction and does not swallow the script", arguments: [
        SqlDialect.postgres, .mysql, .sqlite, .generic,
    ])
    func transactionBeginDoesNotSwallow(dialect: SqlDialect) {
        let sql = "BEGIN;\nUPDATE t SET a = 1;\nCOMMIT;"
        #expect(
            SQLStatementScanner.allStatements(in: sql, dialect: dialect) == [
                "BEGIN", "UPDATE t SET a = 1", "COMMIT",
            ]
        )
    }

    @Test("Named transaction openers are transactions too", arguments: [
        "BEGIN TRANSACTION", "BEGIN WORK", "BEGIN DEFERRED", "BEGIN IMMEDIATE", "BEGIN EXCLUSIVE",
    ])
    func namedTransactionOpeners(opener: String) {
        let sql = "\(opener);\nSELECT 1;\nCOMMIT;"
        #expect(SQLStatementScanner.allStatements(in: sql, dialect: .sqlite).count == 3)
    }

    /// T-SQL abbreviates, and an unmatched `BEGIN TRAN` inside a routine swallows every statement after the routine.
    @Test("BEGIN TRAN inside a routine body does not open a block", arguments: [
        "TRAN", "TRANSACTION", "DISTRIBUTED TRANSACTION",
    ])
    func transactionInsideARoutineDoesNotOpenABlock(opener: String) {
        let sql = """
        CREATE PROCEDURE p AS
        BEGIN
          BEGIN \(opener);
          UPDATE t SET a = 1;
          COMMIT;
        END;
        SELECT * FROM t;
        """
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .generic)
        #expect(statements.count == 2, "got \(statements)")
        #expect(statements.last == "SELECT * FROM t")
    }

    /// `REPEAT ... UNTIL ... END REPEAT` is the one MySQL loop form that is easy to leave off the list, and leaving it
    /// off makes `END REPEAT` pop the routine's own `BEGIN`.
    @Test("END REPEAT does not close the routine body")
    func endRepeatDoesNotClose() {
        let sql = """
        CREATE PROCEDURE p()
        BEGIN
          REPEAT
            SELECT 1;
          UNTIL x END REPEAT;
          SELECT 2;
        END;
        SELECT 3;
        """
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .mysql)
        #expect(statements.count == 2, "got \(statements)")
        #expect(statements.last == "SELECT 3")
    }

    /// The routine flag is per statement. Leaking it forward lets a later statement whose first content is
    /// punctuation inherit permission to open a block, which is the swallow this file exists to prevent.
    @Test("The routine flag does not leak into the next statement")
    func routineFlagDoesNotLeak() {
        let sql = "CREATE TABLE t (a int);\n(SELECT begin FROM t);\nDROP TABLE t;\nSELECT 1;"
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .generic)
        #expect(statements.count == 4, "got \(statements)")
        #expect(statements.last == "SELECT 1")
    }

    @Test("BEGIN ATOMIC opens a routine body")
    func beginAtomicOpensBlock() {
        let sql = "CREATE TRIGGER t BEGIN ATOMIC\n  SELECT 1;\nEND;\nSELECT 2;"
        let statements = SQLStatementScanner.allStatements(in: sql)
        #expect(statements.count == 2)
        #expect(statements.last == "SELECT 2")
    }

    @Test("A bare BEGIN at the end of a document does not swallow anything")
    func bareBeginAtEndOfDocument() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1;\nBEGIN") == ["SELECT 1", "BEGIN"])
    }

    /// A `BEGIN` outside a routine definition must never open a block, however it is written.
    ///
    /// `QueryClassifier.classifyTier` reads a statement's leading keyword, and `BEGIN` is neither a write nor a
    /// destructive one. A `BEGIN` that swallowed the statements after it would hand the execution gate a single
    /// statement starting with `BEGIN`, so a `DROP` inside it would be classified safe and run under Read-Only with
    /// no confirmation.
    @Test("A BEGIN outside a routine definition never swallows the statements after it", arguments: [
        "BEGIN\nDROP TABLE users;\nSELECT 1;",
        "BEGIN\nDELETE FROM t;\nSELECT 1;",
        "SELECT 1;\nBEGIN\nTRUNCATE t;\nSELECT 2;",
    ])
    func beginOutsideARoutineNeverSwallows(sql: String) throws {
        let statements = SQLStatementScanner.allStatements(in: sql, dialect: .postgres)
        let last = try #require(statements.last)
        #expect(statements.count >= 2, "everything merged into one statement: \(statements)")
        #expect(last.hasPrefix("SELECT"), "the trailing SELECT was swallowed: \(statements)")
    }

    @Test("A swallowing BEGIN cannot hide a destructive keyword from the classifier")
    func destructiveKeywordStaysTheLeadingKeyword() {
        let statements = SQLStatementScanner.allStatements(
            in: "BEGIN\nDROP TABLE users;\nSELECT 1;",
            dialect: .postgres
        )
        #expect(statements.count == 2)
        #expect(QueryClassifier.classifyTier(statements[1], databaseType: .postgresql) == .safe)
        #expect(!statements.contains { $0.contains("DROP") && $0.contains("SELECT 1") })
    }

    @Test("A stray END never underflows the block depth")
    func strayEndDoesNotUnderflow() {
        #expect(
            SQLStatementScanner.allStatements(in: "SELECT 1;\nEND;\nSELECT 2;") == ["SELECT 1", "END", "SELECT 2"]
        )
    }

    @Test("An unterminated block takes the rest of the document as one statement")
    func unterminatedBlock() {
        let sql = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n"
        #expect(SQLStatementScanner.allStatements(in: sql, dialect: .mysql).count == 1)
    }

    // MARK: - MySQL hash comments

    @Test("A MySQL # comment hides a semicolon")
    func hashCommentHidesSemicolon() {
        let sql = "SELECT 1; # note; not a split\nSELECT 2;"
        #expect(SQLStatementScanner.allStatements(in: sql, dialect: .mysql).count == 2)
    }

    @Test("# is not a comment outside MySQL")
    func hashIsNotACommentElsewhere() {
        let sql = "SELECT '#a;b';\nSELECT 2;"
        #expect(SQLStatementScanner.allStatements(in: sql, dialect: .postgres) == ["SELECT '#a;b'", "SELECT 2"])
    }

    // MARK: - Opaque bodies

    @Test("A dollar quoted body hides its BEGIN and END")
    func dollarQuotedBodyIsOpaque() {
        let sql = "DO $$ BEGIN PERFORM 1; END $$;\nSELECT 2;"
        #expect(
            SQLStatementScanner.allStatements(in: sql, dialect: .postgres) == [
                "DO $$ BEGIN PERFORM 1; END $$", "SELECT 2",
            ]
        )
    }

    /// The two scanners describe the same routine body, which is the point of sharing ``SqlBlockStructure``: the fold
    /// chevron and the run control in the same gutter must not disagree about where a statement ends. Their ranges are
    /// not identical by design, because a fold starts at the end of the line that opens it so the opening line stays
    /// on screen when it collapses. Containment is the agreement that matters.
    @Test("The fold scanner and the statement scanner agree on a routine body")
    func foldScannerAgreesWithStatementScanner() throws {
        let sql = """
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
          SELECT 2;
        END;
        SELECT 3;
        """
        let statements = SQLStatementScanner.locatedStatements(in: sql, dialect: .mysql)
            .filter(\.hasContent)
        let structure = SQLFoldScanner.scan(sql as NSString, dialect: .mysql)
        let statementRegions = structure.regions.filter { $0.kind == .statement }

        #expect(statements.count == 2)
        #expect(statementRegions.count == 1)

        let body = try #require(statementRegions.first)
        let routine = try #require(statements.first)
        #expect(body.range.lowerBound >= routine.contentRange.location)
        #expect(body.range.upperBound <= routine.contentRange.upperBound)
    }
}
