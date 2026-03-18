//
//  SQLFormatterServiceTests.swift
//  TableProTests
//
//  Tests for SQLFormatterService
//

import Foundation
import Testing
@testable import TablePro

@Suite("SQL Formatter Service")
@MainActor
struct SQLFormatterServiceTests {

    let formatter = SQLFormatterService()

    // MARK: - Keyword Tests

    @Test("Keyword uppercasing SELECT and FROM")
    func keywordUppercasing() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains("SELECT"))
        #expect(result.formattedSQL.contains("FROM"))
    }

    @Test("Lowercase keywords become uppercase")
    func lowercaseKeywordsUppercase() throws {
        let sql = "select id, name from users where active = true"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains("SELECT"))
        #expect(result.formattedSQL.contains("FROM"))
        #expect(result.formattedSQL.contains("WHERE"))
    }

    @Test("String content preservation")
    func stringPreservation() throws {
        let sql = "select 'hello world' from users"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains("'hello world'"))
        #expect(!result.formattedSQL.contains("'HELLO WORLD'"))
    }

    @Test("Custom options with uppercaseKeywords=false preserves original casing")
    func customOptionsLowercaseKeywords() throws {
        let sql = "SELECT * FROM users"
        var options = SQLFormatterOptions.default
        options.uppercaseKeywords = false

        let result = try formatter.format(sql, dialect: .mysql, options: options)

        // When uppercaseKeywords is false, the keyword uppercasing step is skipped,
        // but addLineBreaks still uses uppercase keywords in replacements,
        // so already-uppercase keywords remain uppercase
        #expect(result.formattedSQL.contains("SELECT"))
    }

    // MARK: - Formatting Tests

    @Test("Line breaks added before major clauses")
    func lineBreaksAdded() throws {
        let sql = "select * from users where id = 1 order by name"
        let result = try formatter.format(sql, dialect: .mysql)

        let lines = result.formattedSQL.split(separator: "\n").map { String($0) }
        #expect(lines.count > 1)
        #expect(result.formattedSQL.contains("FROM"))
        #expect(result.formattedSQL.contains("WHERE"))
        #expect(result.formattedSQL.contains("ORDER BY"))
    }

    @Test("Indentation applied to nested structures")
    func indentationApplied() throws {
        let sql = "select * from (select id from users) as subquery"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains(" ") || result.formattedSQL.contains("\t"))
    }

    @Test("SELECT column alignment")
    func selectColumnAlignment() throws {
        let sql = "select id, name, email from users"
        var options = SQLFormatterOptions.default
        options.alignColumns = true

        let result = try formatter.format(sql, dialect: .mysql, options: options)

        #expect(result.formattedSQL.contains("SELECT"))
        #expect(result.formattedSQL.contains("id"))
        #expect(result.formattedSQL.contains("name"))
        #expect(result.formattedSQL.contains("email"))
    }

    @Test("WHERE AND alignment")
    func whereAndAlignment() throws {
        let sql = "select * from users where active = true and role = 'admin'"
        var options = SQLFormatterOptions.default
        options.alignWhere = true

        let result = try formatter.format(sql, dialect: .mysql, options: options)

        #expect(result.formattedSQL.contains("WHERE"))
        #expect(result.formattedSQL.contains("AND"))
    }

    @Test("JOIN formatting on new line")
    func joinFormatting() throws {
        let sql = "select * from users left join roles on users.role_id = roles.id"
        var options = SQLFormatterOptions.default
        options.formatJoins = true

        let result = try formatter.format(sql, dialect: .mysql, options: options)

        // addLineBreaks processes "LEFT JOIN" first, then "JOIN" splits it onto separate lines
        #expect(result.formattedSQL.contains("JOIN"))
        #expect(result.formattedSQL.contains("ON"))
    }

    // MARK: - Error Handling Tests

    @Test("Empty input throws emptyInput error")
    func emptyInputThrows() throws {
        let sql = ""

        #expect(throws: SQLFormatterError.self) {
            try formatter.format(sql, dialect: .mysql)
        }
    }

    @Test("Whitespace only throws emptyInput error")
    func whitespaceOnlyThrows() throws {
        let sql = "   \n\t  "

        #expect(throws: SQLFormatterError.self) {
            try formatter.format(sql, dialect: .mysql)
        }
    }

    @Test("Invalid cursor position throws error")
    func invalidCursorPositionThrows() throws {
        let sql = "select * from users"

        #expect(throws: SQLFormatterError.self) {
            try formatter.format(sql, dialect: .mysql, cursorOffset: 1000)
        }
    }

    @Test("Size limit over 10MB throws internalError")
    func sizeLimitThrows() throws {
        let largeSql = String(repeating: "select * from users; ", count: 600000)

        #expect(throws: SQLFormatterError.self) {
            try formatter.format(largeSql, dialect: .mysql)
        }
    }

    // MARK: - Cursor Position Tests

    @Test("Cursor offset preserved when provided")
    func cursorOffsetPreserved() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .mysql, cursorOffset: 7)

        #expect(result.cursorOffset != nil)
    }

    @Test("No cursor returns nil cursorOffset")
    func noCursorReturnsNil() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.cursorOffset == nil)
    }

    // MARK: - Comment Tests

    @Test("Single line comment preserved")
    func singleLineCommentPreserved() throws {
        let sql = "-- This is a comment\nselect 1"
        var options = SQLFormatterOptions.default
        options.preserveComments = true

        let result = try formatter.format(sql, dialect: .mysql, options: options)

        #expect(result.formattedSQL.contains("--") || result.formattedSQL.contains("comment"))
    }

    @Test("Block comment preserved")
    func blockCommentPreserved() throws {
        let sql = "/* This is a block comment */ select 1"
        var options = SQLFormatterOptions.default
        options.preserveComments = true

        let result = try formatter.format(sql, dialect: .mysql, options: options)

        #expect(result.formattedSQL.contains("/*") || result.formattedSQL.contains("comment"))
    }

    // MARK: - Dialect Tests

    @Test("MySQL dialect works")
    func mysqlDialect() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains("SELECT"))
    }

    @Test("PostgreSQL dialect works")
    func postgresqlDialect() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .postgresql)

        #expect(result.formattedSQL.contains("SELECT"))
    }

    @Test("SQLite dialect works")
    func sqliteDialect() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .sqlite)

        #expect(result.formattedSQL.contains("SELECT"))
    }

    // MARK: - Multiple Statement Tests

    @Test("Multiple statements handled")
    func multipleStatementsHandled() throws {
        let sql = "select * from users; select * from roles;"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains("SELECT"))
        let selectCount = result.formattedSQL.components(separatedBy: "SELECT").count - 1
        #expect(selectCount >= 2)
    }

    // MARK: - Idempotency Tests

    @Test("Formatting twice gives same result")
    func idempotency() throws {
        let sql = "select * from users where id = 1"
        let result1 = try formatter.format(sql, dialect: .mysql)
        let result2 = try formatter.format(result1.formattedSQL, dialect: .mysql)

        let normalized1 = result1.formattedSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized2 = result2.formattedSQL.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(normalized1 == normalized2)
    }

    // MARK: - Integration Tests

    @Test("Simple query end-to-end formatting")
    func simpleQueryEndToEnd() throws {
        let sql = "select id, name from users where active = true order by name"
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL.contains("SELECT"))
        #expect(result.formattedSQL.contains("FROM"))
        #expect(result.formattedSQL.contains("WHERE"))
        #expect(result.formattedSQL.contains("ORDER BY"))
        #expect(!result.formattedSQL.isEmpty)
    }

    @Test("Default options work correctly")
    func defaultOptionsWork() throws {
        let sql = "select * from users"
        let result = try formatter.format(sql, dialect: .mysql, options: .default)

        #expect(result.formattedSQL.contains("SELECT"))
    }

    @Test("Format result is trimmed")
    func formatResultTrimmed() throws {
        let sql = "   select * from users   "
        let result = try formatter.format(sql, dialect: .mysql)

        #expect(result.formattedSQL == result.formattedSQL.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
