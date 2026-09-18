//
//  SQLQueryFingerprintTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLQueryFingerprint")
struct SQLQueryFingerprintTests {
    private func normalize(_ sql: String, _ type: DatabaseType = .postgresql) -> String {
        SQLQueryFingerprint.normalize(sql, databaseType: type)
    }

    private func hash(_ sql: String, _ type: DatabaseType = .postgresql) -> Int64 {
        SQLQueryFingerprint.hash(sql, databaseType: type)
    }

    // MARK: - Literals

    @Test("Literal values collapse so the same lookup is one shape")
    func literalsCollapse() {
        #expect(hash("SELECT * FROM t WHERE id = 1") == hash("SELECT * FROM t WHERE id = 2"))
        #expect(normalize("SELECT * FROM t WHERE id = 1") == "SELECT * FROM t WHERE id = ?")
    }

    @Test("Strings, NULL and booleans are literals")
    func nonNumericLiterals() {
        #expect(normalize("SELECT * FROM t WHERE a = 'x' AND b IS NULL AND c = TRUE")
            == "SELECT * FROM t WHERE a = ? AND b IS ? AND c = ?")
        #expect(hash("SELECT * FROM t WHERE a = 'x'") == hash("SELECT * FROM t WHERE a = 'completely other'"))
    }

    @Test("A password in DDL never survives into the shape")
    func passwordIsReplaced() {
        let shape = normalize("CREATE USER bob IDENTIFIED BY 'hunter2'")
        #expect(shape == "CREATE USER bob IDENTIFIED BY ?")
        #expect(!shape.contains("hunter2"))
    }

    @Test("A sign belonging to a literal does not split the group")
    func unarySignFolds() {
        #expect(hash("SELECT * FROM t WHERE x = -1") == hash("SELECT * FROM t WHERE x = 1"))
        #expect(normalize("SELECT b - 1 FROM t") == "SELECT b - ? FROM t")
        #expect(normalize("SELECT f(a, -1) FROM t") == "SELECT f(a, ?) FROM t")
        #expect(normalize("SELECT * FROM t WHERE x BETWEEN -1 AND 5") == "SELECT * FROM t WHERE x BETWEEN ? AND ?")
    }

    /// Sign detection used to read the previous token's spelling, and identifier case is preserved,
    /// so an uppercase column name was mistaken for a keyword: subtraction and addition on it both
    /// collapsed to `TOTAL ?`, merging two different statements into one shape.
    @Test("An uppercase identifier is not mistaken for a keyword before a sign")
    func uppercaseIdentifierIsNotAKeyword() {
        #expect(normalize("SELECT TOTAL - 1 FROM t") == "SELECT TOTAL - ? FROM t")
        #expect(hash("SELECT TOTAL - 1 FROM t") != hash("SELECT TOTAL + 1 FROM t"))
        #expect(normalize("SELECT tags[1] - 1 FROM t") == "SELECT tags[?] - ? FROM t")
        #expect(normalize("SELECT f(a) - 1 FROM t") == "SELECT f(a) - ? FROM t")
    }

    @Test("A call binds to its arguments while a clause keyword keeps its space")
    func parenthesisSpacing() {
        #expect(normalize("SELECT count(*), sum(total) FROM t") == "SELECT COUNT(*), SUM(total) FROM t")
        #expect(normalize("SELECT (1) FROM t") == "SELECT (?) FROM t")
        #expect(normalize("SELECT * FROM t WHERE id IN (1, 2)") == "SELECT * FROM t WHERE id IN (...)")
    }

    @Test("Bound parameters group with the same query typed literally")
    func placeholdersFoldIntoLiterals() {
        #expect(hash("SELECT * FROM t WHERE id = $1") == hash("SELECT * FROM t WHERE id = 7"))
        #expect(hash("SELECT * FROM t WHERE id = ?") == hash("SELECT * FROM t WHERE id = 7"))
    }

    // MARK: - Identifiers

    @Test("A double-quoted identifier is not a literal outside MySQL")
    func doubleQuotedIdentifiersSurvive() {
        let users = normalize(#"SELECT "email" FROM "Users" WHERE id = 1"#)
        let orders = normalize(#"SELECT "phone" FROM "Orders" WHERE id = 2"#)
        #expect(users == "SELECT email FROM Users WHERE id = ?")
        #expect(users != orders)
    }

    @Test("MySQL reads a double-quoted value as a string")
    func mysqlDoubleQuoteIsString() {
        #expect(normalize(#"SELECT * FROM t WHERE n = "bob""#, .mysql) == "SELECT * FROM t WHERE n = ?")
        #expect(hash(#"SELECT * FROM t WHERE n = "bob""#, .mysql)
            == hash(#"SELECT * FROM t WHERE n = "alice""#, .mysql))
    }

    @Test("Quoted and unquoted spellings of one identifier are one shape")
    func identifierQuotingUnified() {
        #expect(hash("SELECT * FROM `users`", .mysql) == hash("SELECT * FROM users", .mysql))
        #expect(hash(#"SELECT * FROM "users""#) == hash("SELECT * FROM users"))
        #expect(hash("SELECT * FROM [users]", .mssql) == hash("SELECT * FROM users", .mssql))
    }

    @Test("Identifier case is preserved so two real tables never merge")
    func identifierCasePreserved() {
        #expect(hash("SELECT * FROM Orders") != hash("SELECT * FROM orders"))
    }

    @Test("A number inside an identifier is part of the name")
    func numbersInIdentifiersSurvive() {
        #expect(hash("SELECT * FROM users_2009") != hash("SELECT * FROM users_2010"))
        #expect(normalize("SELECT catch22 FROM t") == "SELECT catch22 FROM t")
    }

    @Test("A PostgreSQL array subscript is not mistaken for a quoted identifier")
    func arraySubscriptSurvives() {
        #expect(normalize("SELECT tags[1] FROM t") == "SELECT tags[?] FROM t")
    }

    // MARK: - Lists

    @Test("An IN list collapses regardless of how many values it holds")
    func inListCollapses() {
        #expect(normalize("SELECT * FROM t WHERE id IN (1, 2, 3)") == "SELECT * FROM t WHERE id IN (...)")
        #expect(hash("SELECT * FROM t WHERE id IN (1, 2)") == hash("SELECT * FROM t WHERE id IN (1, 2, 3, 4, 5)"))
    }

    @Test("An IN subquery is part of the shape, not its arguments")
    func inSubqueryIsNotCollapsed() {
        #expect(normalize("SELECT * FROM t WHERE id IN (SELECT id FROM u)")
            == "SELECT * FROM t WHERE id IN (SELECT id FROM u)")
    }

    @Test("A multi-row insert groups with a single-row insert into the same table")
    func valuesListCollapses() {
        #expect(normalize("INSERT INTO t VALUES (1, 'a'), (2, 'b')") == "INSERT INTO t VALUES (...)")
        #expect(hash("INSERT INTO t VALUES (1, 'a')") == hash("INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')"))
    }

    // MARK: - Noise

    @Test("Whitespace, keyword case and comments do not split a group")
    func formattingIsIgnored() {
        #expect(hash("select * from t where id=1") == hash("SELECT  *\n  FROM t\n  WHERE id = 2"))
        #expect(hash("-- pick\nSELECT * FROM t /* hint */ WHERE id=1") == hash("SELECT * FROM t WHERE id=2"))
    }

    @Test("A dollar-quoted body never leaks into the shape")
    func dollarQuotedBodiesAreStripped() {
        let shape = normalize("SELECT $$secret payload$$ FROM t")
        #expect(shape == "SELECT ? FROM t")
        #expect(!shape.contains("secret"))
        #expect(hash("SELECT $$a$$ FROM t") == hash("SELECT $$totally different$$ FROM t"))
        #expect(!normalize("SELECT $tag$body here$tag$ FROM t").contains("body"))
    }

    // MARK: - Distinctness

    @Test("Different tables and columns stay in different groups")
    func distinctQueriesStayDistinct() {
        #expect(hash("SELECT * FROM users WHERE id = 1") != hash("SELECT * FROM orders WHERE id = 1"))
        #expect(hash("SELECT a FROM t") != hash("SELECT b FROM t"))
        #expect(hash("UPDATE t SET a = 1") != hash("DELETE FROM t WHERE a = 1"))
    }

    // MARK: - Stability

    @Test("The digest is stable across processes, so a stored column stays valid")
    func digestIsProcessStable() {
        // The literal pins the value. Were the digest derived from `Hasher`, which is seeded per
        // process, this would pass in one launch and fail in the next, and every fingerprint
        // already stored on disk would stop matching the moment the app restarted.
        #expect(SQLQueryFingerprint.digest(of: "SELECT * FROM t WHERE id = ?") == 1_936_778_350_161_199_288)
        #expect(hash("SELECT * FROM t WHERE id = 5") == 1_936_778_350_161_199_288)
        #expect(SQLQueryFingerprint.digest(of: "a") != SQLQueryFingerprint.digest(of: "b"))
    }

    @Test("An oversized statement is truncated rather than tokenized whole")
    func oversizedStatementIsCapped() {
        let long = "SELECT * FROM t WHERE x IN (" + Array(repeating: "1", count: 40_000).joined(separator: ",") + ")"
        let shape = normalize(long)
        #expect(!shape.isEmpty)
        #expect((shape as NSString).length < SQLQueryFingerprint.maxSourceLength)
    }

    @Test("An empty or whitespace-only statement does not crash")
    func emptyInputIsSafe() {
        #expect(normalize("") == "")
        #expect(normalize("   \n\t ") == "")
    }
}
