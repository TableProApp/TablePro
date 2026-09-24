//
//  QueryClassifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

@Suite("QueryClassifier isExplainStatement")
struct QueryClassifierExplainTests {
    @Test("Detects EXPLAIN and EXPLAIN ANALYZE variants")
    func detectsExplainVariants() {
        #expect(QueryClassifier.isExplainStatement("EXPLAIN SELECT * FROM users"))
        #expect(QueryClassifier.isExplainStatement("explain analyze select o.user_id from orders o"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN ANALYZE SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN FORMAT=JSON SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN (ANALYZE, BUFFERS) SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN(FORMAT JSON) SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN QUERY PLAN SELECT 1"))
    }

    @Test("Detects MariaDB ANALYZE statements")
    func detectsAnalyzeVariants() {
        #expect(QueryClassifier.isExplainStatement("ANALYZE FORMAT=JSON SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("analyze select 1"))
    }

    @Test("Ignores leading whitespace, newlines, and comments")
    func handlesWhitespaceAndComments() {
        #expect(QueryClassifier.isExplainStatement("   EXPLAIN SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("\n\tEXPLAIN\nSELECT 1"))
        #expect(QueryClassifier.isExplainStatement("-- plan check\nEXPLAIN SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("/* warm cache */ EXPLAIN ANALYZE SELECT 1"))
    }

    @Test("Does not match DESCRIBE, identifiers, or other statements")
    func rejectsNonExplain() {
        #expect(!QueryClassifier.isExplainStatement("DESCRIBE users"))
        #expect(!QueryClassifier.isExplainStatement("DESC users"))
        #expect(!QueryClassifier.isExplainStatement("SELECT * FROM explain_logs"))
        #expect(!QueryClassifier.isExplainStatement("SELECT explain FROM t"))
        #expect(!QueryClassifier.isExplainStatement("EXPLAINING SELECT 1"))
        #expect(!QueryClassifier.isExplainStatement("EXPLAIN"))
        #expect(!QueryClassifier.isExplainStatement(""))
    }
}

@Suite("QueryClassifier explainedStatement")
struct QueryClassifierExplainedStatementTests {
    @Test("Preserves line comments between EXPLAIN options and the statement")
    func preservesLineCommentBeforeStatement() throws {
        let subject = "-- compare this plan\nSELECT * FROM users"
        let explicitSubject = try #require(SQLStatementScanner.executableStatements(in: subject).first?.sql)

        #expect(
            QueryClassifier.explainedStatement(in: "EXPLAIN QUERY PLAN \(subject)")
                == explicitSubject
        )
    }

    @Test("Preserves block comments between parenthesized options and the statement")
    func preservesBlockCommentBeforeStatement() throws {
        let subject = "/* compare this plan */ SELECT * FROM users"
        let explicitSubject = try #require(SQLStatementScanner.executableStatements(in: subject).first?.sql)

        #expect(
            QueryClassifier.explainedStatement(in: "EXPLAIN (ANALYZE, BUFFERS) \(subject)")
                == explicitSubject
        )
    }

    @Test("Preserves nested block comments before the statement")
    func preservesNestedBlockCommentBeforeStatement() throws {
        let subject = "/* outer /* inner */ still outer */ SELECT 1"
        let explicitSubject = try #require(SQLStatementScanner.executableStatements(in: subject).first?.sql)

        #expect(
            QueryClassifier.explainedStatement(in: "EXPLAIN (FORMAT JSON) \(subject)")
                == explicitSubject
        )
    }

    @Test("Comments inside EXPLAIN options do not become statement comments")
    func skipsCommentsInsideOptions() {
        #expect(
            QueryClassifier.explainedStatement(
                in: "EXPLAIN FORMAT /* option separator */ = JSON /* statement */ SELECT 1"
            ) == "/* statement */ SELECT 1"
        )
    }
}

@Suite("QueryClassifier classification with leading comments")
struct QueryClassifierLeadingCommentTests {
    @Test("isWriteQuery detects writes preceded by comments")
    func writeDetectionWithComments() {
        #expect(QueryClassifier.isWriteQuery("-- cleanup\nDELETE FROM users", databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery("/* batch */ INSERT INTO t VALUES (1)", databaseType: .postgresql))
        #expect(!QueryClassifier.isWriteQuery("-- note\nSELECT * FROM users", databaseType: .mysql))
    }

    @Test("isDangerousQuery detects destructive statements preceded by comments")
    func dangerousDetectionWithComments() {
        #expect(QueryClassifier.isDangerousQuery("-- reset\nDROP TABLE users", databaseType: .mysql))
        #expect(QueryClassifier.isDangerousQuery("/* wipe */ TRUNCATE users", databaseType: .postgresql))
        #expect(QueryClassifier.isDangerousQuery("-- purge\nDELETE FROM users", databaseType: .mysql))
        #expect(!QueryClassifier.isDangerousQuery("-- purge\nDELETE FROM users WHERE id = 1", databaseType: .mysql))
    }

    @Test("classifyTier classifies statements preceded by comments")
    func tierClassificationWithComments() {
        #expect(QueryClassifier.classifyTier("-- reset\nDROP TABLE users", databaseType: .mysql) == .destructive)
        #expect(QueryClassifier.classifyTier("/* batch */ UPDATE t SET x = 1", databaseType: .mysql) == .write)
        #expect(QueryClassifier.classifyTier("-- note\nSELECT 1", databaseType: .mysql) == .safe)
    }
}

@Suite("QueryClassifier keyword boundary handling")
struct QueryClassifierKeywordBoundaryTests {
    @Test("isWriteQuery detects writes followed by newline or tab")
    func writeDetectionAcrossWhitespace() {
        #expect(QueryClassifier.isWriteQuery("DELETE\nFROM users", databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery("INSERT\tINTO t VALUES (1)", databaseType: .postgresql))
        #expect(QueryClassifier.classifyTier("DELETED_ROWS", databaseType: .mysql) != .destructive)
        #expect(!QueryClassifier.isDangerousQuery("DELETED_ROWS", databaseType: .mysql))
    }

    @Test("isDangerousQuery detects destructive statements followed by newline")
    func dangerousDetectionAcrossWhitespace() {
        #expect(QueryClassifier.isDangerousQuery("DROP\nTABLE users", databaseType: .mysql))
        #expect(QueryClassifier.isDangerousQuery("DELETE\nFROM users", databaseType: .mysql))
        #expect(!QueryClassifier.isDangerousQuery("DELETE\nFROM users WHERE id = 1", databaseType: .mysql))
    }

    @Test("classifyTier classifies statements followed by newline")
    func tierClassificationAcrossWhitespace() {
        #expect(QueryClassifier.classifyTier("TRUNCATE\nusers", databaseType: .mysql) == .destructive)
        #expect(QueryClassifier.classifyTier("UPDATE\nt SET x = 1", databaseType: .mysql) == .write)
    }
}

@Suite("QueryClassifier parenthesised statements")
struct QueryClassifierParenthesisedTests {
    @Test("leadingKeyword reaches past opening parentheses")
    func leadingKeywordSkipsParens() {
        #expect(QueryClassifier.leadingKeyword(of: "(SELECT * FROM t)") == "SELECT")
        #expect(QueryClassifier.leadingKeyword(of: "((SELECT * FROM t))") == "SELECT")
        #expect(QueryClassifier.leadingKeyword(of: "( /* c */ SELECT 1 )") == "SELECT")
        #expect(QueryClassifier.leadingKeyword(of: "(  VALUES (1), (2)") == "VALUES")
    }

    @Test("A parenthesised set operation reads as safe")
    func parenthesisedUnionIsSafe() {
        let sql = "(SELECT * FROM events ORDER BY id) UNION ALL (SELECT * FROM events_archive)"
        #expect(!QueryClassifier.isWriteQuery(sql, databaseType: .postgresql))
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .safe)
    }

    @Test("Skipping parentheses cannot downgrade a write or a destructive statement")
    func parenthesesDoNotDowngradeWrites() {
        #expect(QueryClassifier.isWriteQuery("(DELETE FROM users)", databaseType: .postgresql))
        #expect(QueryClassifier.classifyTier("(DROP TABLE users)", databaseType: .postgresql) == .destructive)
        #expect(QueryClassifier.classifyTier("(UPDATE t SET x = 1)", databaseType: .postgresql) == .write)
        #expect(QueryClassifier.isWriteQuery("(SELECT * INTO backup FROM t)", databaseType: .postgresql))
    }

    @Test("A filesystem or code surface inside parentheses is still flagged")
    func parenthesesDoNotHideUnsafeSurface() {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(
            "(COPY t FROM PROGRAM 'sh')", databaseType: .postgresql
        ))
    }
}

@Suite("QueryClassifier isMultiStatement")
struct QueryClassifierMultiStatementTests {
    @Test("A trailing comment after the terminating semicolon is not a second statement")
    func trailingCommentIsNotMultiStatement() {
        #expect(!QueryClassifier.isMultiStatement("SELECT 1; -- note", databaseType: .mysql))
        #expect(!QueryClassifier.isMultiStatement("SELECT 1; /* note */", databaseType: .postgresql))
    }

    @Test("Two real statements are still multi-statement")
    func twoRealStatementsAreMultiStatement() {
        #expect(QueryClassifier.isMultiStatement("SELECT 1; SELECT 2", databaseType: .mysql))
    }

    @Test("A comment-only query is not multi-statement")
    func commentOnlyQueryIsNotMultiStatement() {
        #expect(!QueryClassifier.isMultiStatement("-- note", databaseType: .mysql))
    }
}

/// T-SQL needs no `;` between statements. Each text below was sent whole to Azure SQL Edge 15.0, which ran every
/// statement in it, so the classifier has to tier the ones written after the first as well.
@Suite("QueryClassifier statements SQL Server runs without a terminator")
struct QueryClassifierUnterminatedStatementTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let sql: String
        let tier: QueryTier
        let deletesEverything: Bool

        var testDescription: String { sql }
    }

    static let hidden: [Case] = [
        Case(sql: "SELECT 1\nDROP TABLE t", tier: .destructive, deletesEverything: true),
        Case(sql: "SELECT 1 DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "PRINT 'x' UPDATE t SET c = 1", tier: .write, deletesEverything: false),
        Case(sql: "SELECT 1 TRUNCATE TABLE t", tier: .destructive, deletesEverything: true),
        Case(sql: "SELECT 1 EXEC('DELETE FROM t')", tier: .write, deletesEverything: false),
        Case(sql: "SELECT 1DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "SELECT $1DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "SELECT 1\u{200B}DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "SELECT DB_NAME() USE master", tier: .write, deletesEverything: false),
        Case(sql: "SET NOCOUNT ON DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "WAITFOR DELAY '00:00:00' DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "IF 1 = 0 SELECT 1 ELSE DELETE FROM t", tier: .write, deletesEverything: true),
        Case(sql: "DELETE FROM t SELECT 1 WHERE 1 = 1", tier: .write, deletesEverything: true),
        Case(sql: "CREATE TYPE dbo.t FROM int DROP TABLE x", tier: .destructive, deletesEverything: true),
        Case(sql: "SELECT 1\nUPDATE [t] SET c = 1", tier: .write, deletesEverything: false),
        Case(sql: "SELECT 1\nUPDATE \"t\" SET c = 1", tier: .write, deletesEverything: false),
        Case(sql: "PRINT 1\nUPDATE [t]\nSET c = 1", tier: .write, deletesEverything: false),
        Case(sql: "PRINT 1\nSELECT [a], [b] INTO x FROM t", tier: .write, deletesEverything: false),
        Case(sql: "PRINT 1\nDELETE [t]", tier: .write, deletesEverything: true),
        Case(
            sql: "INSERT INTO log SELECT id FROM (DELETE FROM t OUTPUT deleted.id) AS d",
            tier: .write,
            deletesEverything: true
        ),
    ]

    @Test("A statement written after another without a terminator is tiered", arguments: hidden)
    func hiddenStatementIsTiered(_ hidden: Case) {
        #expect(QueryClassifier.classifyTier(hidden.sql, databaseType: .mssql) == hidden.tier)
        #expect(QueryClassifier.isWriteQuery(hidden.sql, databaseType: .mssql))
        #expect(QueryClassifier.isDangerousQuery(hidden.sql, databaseType: .mssql) == hidden.deletesEverything)
    }

    @Test("A backup written after a read reaches the filesystem")
    func hiddenBackupReachesTheFilesystem() {
        let sql = "SELECT 1 BACKUP DATABASE d TO DISK = '/tmp/d.bak'"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .mssql))
    }

    @Test("A read that only names a statement keyword stays a read", arguments: [
        "SELECT deleted_at, last_update FROM t",
        "SELECT [delete], \"update\" FROM t",
        "SELECT 'DROP TABLE t' AS s -- DELETE FROM t",
        "SELECT 1\nSELECT 2",
        "SELECT [a], 'b' FROM [t] WHERE [c] = 'd'",
        "SELECT 1 PRINT 'done'",
        "SELECT * FROM t WHERE id IN (SELECT id FROM s)",
        "SELECT CASE WHEN a = 1 THEN 'x' ELSE 'y' END FROM t",
        "SELECT a.id FROM t a INNER MERGE JOIN s b ON a.id = b.id OPTION (MERGE JOIN, USE HINT('X'))",
        "SELECT id FROM t ORDER BY id OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY",
        "SELECT 0xDELETE FROM t",
        "SELECT 1 éDELETE FROM t",
        "WITH c AS (SELECT 1 AS x) SELECT * FROM c",
    ])
    func readsStayReads(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .safe)
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .mssql))
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .mssql))
    }

    @Test("Storing a procedure runs nothing written after its header")
    func routineBodyIsNotRun() {
        let sql = "CREATE PROCEDURE dbo.p AS SELECT 1 DROP TABLE t"
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .write)
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .mssql))
    }

    @Test("An engine that needs a terminator keeps reading a statement by its first word", arguments: [
        DatabaseType.mysql, .postgresql, .sqlite, .oracle,
    ])
    func terminatedEnginesAreUnchanged(databaseType: DatabaseType) {
        #expect(QueryClassifier.classifyTier("SELECT open, close, print FROM prices", databaseType: databaseType)
            == .safe)
        #expect(QueryClassifier.classifyTier("SELECT 1; DELETE FROM t", databaseType: databaseType) == .write)
    }
}
