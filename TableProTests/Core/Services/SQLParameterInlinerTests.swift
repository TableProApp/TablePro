//
//  SQLParameterInlinerTests.swift
//  TableProTests
//
//  Tests for SQLParameterInliner.swift
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQL Parameter Inliner")
struct SQLParameterInlinerTests {
    @Test("Simple ? replacement for MySQL")
    func simpleQuestionMarkReplacementMySQL() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE id = ?",
            parameters: [42]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users WHERE id = 42")
    }

    @Test("Multiple ? placeholders for MySQL")
    func multipleQuestionMarksMySQL() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE id = ? AND status = ? AND age > ?",
            parameters: [42, "active", 18]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users WHERE id = 42 AND status = 'active' AND age > 18")
    }

    @Test("NULL parameter becomes NULL")
    func nullParameterReplacement() {
        let statement = ParameterizedStatement(
            sql: "UPDATE users SET email = ? WHERE id = ?",
            parameters: [nil, 10]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "UPDATE users SET email = NULL WHERE id = 10")
    }

    @Test("String parameter gets quoted and escaped")
    func stringParameterQuoted() {
        let statement = ParameterizedStatement(
            sql: "INSERT INTO users (name) VALUES (?)",
            parameters: ["John Doe"]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "INSERT INTO users (name) VALUES ('John Doe')")
    }

    @Test("String with single quote gets escaped")
    func stringWithSingleQuote() {
        let statement = ParameterizedStatement(
            sql: "INSERT INTO users (name) VALUES (?)",
            parameters: ["O'Brien"]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "INSERT INTO users (name) VALUES ('O''Brien')")
    }

    @Test("Bool true becomes TRUE")
    func boolTrueParameter() {
        let statement = ParameterizedStatement(
            sql: "UPDATE users SET active = ? WHERE id = ?",
            parameters: [true, 5]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "UPDATE users SET active = TRUE WHERE id = 5")
    }

    @Test("Bool false becomes FALSE")
    func boolFalseParameter() {
        let statement = ParameterizedStatement(
            sql: "UPDATE users SET verified = ?",
            parameters: [false]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "UPDATE users SET verified = FALSE")
    }

    @Test("$1 replacement for PostgreSQL")
    func dollarOneReplacementPostgreSQL() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE id = $1",
            parameters: [42]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .postgresql)

        #expect(result == "SELECT * FROM users WHERE id = 42")
    }

    @Test("Multiple $N placeholders for PostgreSQL")
    func multipleDollarPlaceholdersPostgreSQL() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE id = $1 AND status = $2 AND age > $3",
            parameters: [42, "active", 18]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .postgresql)

        #expect(result == "SELECT * FROM users WHERE id = 42 AND status = 'active' AND age > 18")
    }

    @Test("$N placeholders out of order for PostgreSQL")
    func dollarPlaceholdersOutOfOrder() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE status = $2 AND id = $1",
            parameters: [42, "active"]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .postgresql)

        #expect(result == "SELECT * FROM users WHERE status = 'active' AND id = 42")
    }

    @Test("Skip ? inside string literal")
    func skipQuestionMarkInStringLiteral() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE name = '?' AND id = ?",
            parameters: [42]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users WHERE name = '?' AND id = 42")
    }

    @Test("Skip $1 inside string literal")
    func skipDollarInStringLiteral() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE name = '$1' AND id = $1",
            parameters: [42]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .postgresql)

        #expect(result == "SELECT * FROM users WHERE name = '$1' AND id = 42")
    }

    @Test("Empty parameters with no placeholders")
    func emptyParametersNoPlaceholders() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users",
            parameters: []
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users")
    }

    @Test("Int parameter types")
    func intParameterTypes() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE id = ? AND count = ?",
            parameters: [Int(42), Int64(100)]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users WHERE id = 42 AND count = 100")
    }

    @Test("Float and Double parameters")
    func floatAndDoubleParameters() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM products WHERE price = ? AND weight = ?",
            parameters: [Float(19.99), Double(2.5)]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM products WHERE price = 19.99 AND weight = 2.5")
    }

    @Test("Mixed parameter types")
    func mixedParameterTypes() {
        let statement = ParameterizedStatement(
            sql: "INSERT INTO users (name, age, active, email) VALUES (?, ?, ?, ?)",
            parameters: ["Alice", 30, true, nil]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "INSERT INTO users (name, age, active, email) VALUES ('Alice', 30, TRUE, NULL)")
    }

    @Test("Empty SQL string")
    func emptySQLString() {
        let statement = ParameterizedStatement(
            sql: "",
            parameters: []
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "")
    }

    @Test("Escaped single quote in SQL string literal")
    func escapedQuoteInLiteral() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE name = 'O''Brien' AND id = ?",
            parameters: [42]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users WHERE name = 'O''Brien' AND id = 42")
    }

    @Test("Multiple parameters in same SQL column")
    func multipleParametersSameColumn() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE status IN (?, ?, ?)",
            parameters: ["active", "pending", "verified"]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT * FROM users WHERE status IN ('active', 'pending', 'verified')")
    }

    @Test("No parameters and no placeholders")
    func noParametersNoPlaceholders() {
        let statement = ParameterizedStatement(
            sql: "SELECT COUNT(*) FROM users",
            parameters: []
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result == "SELECT COUNT(*) FROM users")
    }

    @Test("SQLite uses question mark placeholders")
    func sqliteQuestionMarkReplacement() {
        let statement = ParameterizedStatement(
            sql: "SELECT * FROM users WHERE id = ? AND name = ?",
            parameters: [42, "John"]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .sqlite)

        #expect(result == "SELECT * FROM users WHERE id = 42 AND name = 'John'")
    }

    @Test("MariaDB uses question mark placeholders")
    func mariadbQuestionMarkReplacement() {
        let statement = ParameterizedStatement(
            sql: "DELETE FROM users WHERE id = ?",
            parameters: [10]
        )

        let result = SQLParameterInliner.inline(statement, databaseType: .mariadb)

        #expect(result == "DELETE FROM users WHERE id = 10")
    }

    @Test("Large SQL with ? placeholders performs correctly")
    func largeSQL() {
        let columns = (0..<100).map { "col\($0) = ?" }.joined(separator: " AND ")
        let sql = "UPDATE large_table SET \(columns)"
        let params: [Any?] = (0..<100).map { $0 as Any? }
        let statement = ParameterizedStatement(sql: sql, parameters: params)

        let result = SQLParameterInliner.inline(statement, databaseType: .mysql)

        #expect(result.contains("col0 = 0"))
        #expect(result.contains("col99 = 99"))
        #expect(!result.contains("?"))
    }
}
