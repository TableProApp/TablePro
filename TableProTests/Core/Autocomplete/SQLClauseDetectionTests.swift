//
//  SQLClauseDetectionTests.swift
//  TableProTests
//
//  Full coverage for nearest-clause detection: the cursor's clause is the clause
//  keyword closest to it, not the highest-priority keyword anywhere in the
//  statement. Covers the multi-join / multi-clause regressions from #1646 plus
//  the operand-slot, CASE, parenthesis, quoting, and table-extraction matrix.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Clause Detection")
struct SQLClauseDetectionTests {
    private let analyzer = SQLContextAnalyzer()

    private func clause(_ query: String) -> SQLClauseType {
        analyzer.analyze(query: query, cursorPosition: (query as NSString).length).clauseType
    }

    private func context(_ query: String) -> SQLContext {
        analyzer.analyze(query: query, cursorPosition: (query as NSString).length)
    }

    // MARK: - Linear Clause Progression

    @Test("Single-clause queries detect the trailing clause", arguments: [
        (query: "SELECT ", expected: SQLClauseType.select),
        (query: "SELECT id FROM ", expected: .from),
        (query: "SELECT id FROM users ", expected: .from),
        (query: "SELECT id FROM users WHERE ", expected: .where_),
        (query: "SELECT id FROM users WHERE id = 1 AND ", expected: .and),
        (query: "SELECT id FROM users WHERE id = 1 OR ", expected: .and),
        (query: "SELECT id FROM users GROUP BY ", expected: .groupBy),
        (query: "SELECT id FROM users ORDER BY ", expected: .orderBy),
        (query: "SELECT id FROM users GROUP BY id HAVING ", expected: .having),
        (query: "SELECT id FROM users LIMIT ", expected: .limit),
        (query: "UPDATE users SET ", expected: .set),
        (query: "INSERT INTO ", expected: .into),
        (query: "SELECT 1 UNION ", expected: .union),
        (query: "SELECT * FROM users RETURNING ", expected: .returning),
    ])
    func linearClause(_ testCase: (query: String, expected: SQLClauseType)) {
        #expect(clause(testCase.query) == testCase.expected)
    }

    // MARK: - Nearest Clause Wins Over an Earlier Clause

    @Test("The clause nearest the cursor wins, not the earlier higher-priority one", arguments: [
        (query: "SELECT * FROM a JOIN b ON a.id = b.id INNER JOIN ", expected: SQLClauseType.join),
        (query: "SELECT * FROM a LEFT JOIN b ON a.x = b.x RIGHT JOIN ", expected: .join),
        (query: "SELECT * FROM a JOIN b ON a.id = b.id JOIN c ON b.id = c.id INNER JOIN ", expected: .join),
        (query: "SELECT * FROM a JOIN b ON a.id = b.id WHERE ", expected: .where_),
        (query: "SELECT * FROM a JOIN b ON a.id = b.id AND ", expected: .and),
        (query: "UPDATE users SET name = 'x' WHERE ", expected: .where_),
        (query: "SELECT * FROM t WHERE a = 1 GROUP BY ", expected: .groupBy),
        (query: "SELECT * FROM t GROUP BY x HAVING count(*) > 1 ORDER BY ", expected: .orderBy),
    ])
    func nearestClauseWins(_ testCase: (query: String, expected: SQLClauseType)) {
        #expect(clause(testCase.query) == testCase.expected)
    }

    // MARK: - Case Insensitivity

    @Test("Clause detection is case insensitive", arguments: [
        (query: "select * from a join b on a.id = b.id inner join ", expected: SQLClauseType.join),
        (query: "Select Id From Users Where ", expected: .where_),
        (query: "select * from t group by x having 1 = 1 order by ", expected: .orderBy),
    ])
    func caseInsensitiveClause(_ testCase: (query: String, expected: SQLClauseType)) {
        #expect(clause(testCase.query) == testCase.expected)
    }

    // MARK: - CASE ... END Boundary

    @Test("CASE expressions and their END boundary are tracked", arguments: [
        (query: "SELECT CASE WHEN ", expected: SQLClauseType.caseExpression),
        (query: "SELECT CASE WHEN x = 1 THEN ", expected: .caseExpression),
        (query: "SELECT CASE WHEN a THEN b ELSE ", expected: .caseExpression),
        (query: "SELECT CASE WHEN a THEN b END, ", expected: .select),
        (query: "SELECT CASE WHEN a THEN b END FROM ", expected: .from),
        (query: "SELECT CASE WHEN a THEN CASE WHEN b THEN c END END, ", expected: .select),
    ])
    func caseExpressionBoundary(_ testCase: (query: String, expected: SQLClauseType)) {
        #expect(clause(testCase.query) == testCase.expected)
    }

    // MARK: - Parentheses and Subqueries

    @Test("Function calls, closed parens, and subqueries scope clause detection", arguments: [
        (query: "SELECT COUNT(", expected: SQLClauseType.select),
        (query: "SELECT * FROM t WHERE fn(x) AND ", expected: .and),
        (query: "SELECT SUM(amount) FROM t WHERE ", expected: .where_),
        (query: "SELECT (SELECT max(x) FROM b) FROM a ", expected: .from),
        (query: "SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE ", expected: .where_),
    ])
    func parenthesisScoping(_ testCase: (query: String, expected: SQLClauseType)) {
        #expect(clause(testCase.query) == testCase.expected)
    }

    // MARK: - Quoted Identifiers

    @Test("A quoted reserved word is an identifier, not a clause keyword", arguments: [
        "SELECT * FROM orders WHERE `order` = ",
        "SELECT * FROM orders WHERE \"order\" = ",
    ])
    func quotedReservedWordIsNotClause(_ query: String) {
        #expect(clause(query) == .where_)
    }

    // MARK: - Unknown / Empty

    @Test("Empty or keyword-free text is unknown", arguments: [
        "",
        "   ",
        "\t\n ",
        "randomword ",
    ])
    func unknownClause(_ query: String) {
        #expect(clause(query) == .unknown)
    }

    // MARK: - Operand Slot (expectsObjectName)

    @Test("expectsObjectName is true only in a table-operand slot", arguments: [
        (query: "SELECT * FROM ", clause: SQLClauseType.from, expects: true),
        (query: "SELECT * FROM users ", clause: .from, expects: false),
        (query: "SELECT * FROM a, ", clause: .from, expects: true),
        (query: "SELECT * FROM a, b ", clause: .from, expects: false),
        (query: "SELECT * FROM users JOIN ", clause: .join, expects: true),
        (query: "SELECT * FROM users JOIN orders ", clause: .join, expects: false),
        (query: "SELECT * FROM users INNER JOIN ", clause: .join, expects: true),
        (query: "INSERT INTO ", clause: .into, expects: true),
        (query: "INSERT INTO users ", clause: .into, expects: false),
        (query: "SELECT * FROM users WHERE ", clause: .where_, expects: false),
        (query: "SELECT ", clause: .select, expects: false),
    ])
    func operandSlot(_ testCase: (query: String, clause: SQLClauseType, expects: Bool)) {
        let ctx = context(testCase.query)
        #expect(ctx.clauseType == testCase.clause)
        #expect(ctx.expectsObjectName == testCase.expects)
    }

    // MARK: - String and Comment Guards

    @Test("Clause keywords inside a string literal are ignored")
    func keywordsInStringIgnored() {
        #expect(clause("SELECT * FROM users WHERE name = 'FROM JOIN' AND ") == .and)
    }

    @Test("A cursor inside an unterminated string reports no clause")
    func cursorInsideStringIsUnknown() {
        let ctx = context("SELECT * FROM users WHERE name = 'unclosed ")
        #expect(ctx.isInsideString)
        #expect(ctx.clauseType == .unknown)
    }

    // MARK: - Multi-Statement

    @Test("Detection uses the statement under the cursor")
    func multiStatementUsesCurrent() {
        let ctx = context("SELECT * FROM a; SELECT * FROM ")
        #expect(ctx.clauseType == .from)
        #expect(ctx.expectsObjectName)
    }

    // MARK: - Table Reference Extraction

    @Test("Comma-separated FROM lists put every table in scope")
    func commaSeparatedTables() {
        let ctx = context("SELECT * FROM a, b, c WHERE ")
        #expect(ctx.clauseType == .where_)
        #expect(ctx.tableReferences.contains { $0.tableName == "a" })
        #expect(ctx.tableReferences.contains { $0.tableName == "b" })
        #expect(ctx.tableReferences.contains { $0.tableName == "c" })
    }

    @Test("Aliases in a comma-separated FROM list are captured")
    func commaSeparatedAliases() {
        let ctx = context("SELECT * FROM users u, orders o WHERE ")
        #expect(ctx.tableReferences.contains { $0.tableName == "users" && $0.alias == "u" })
        #expect(ctx.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    @Test("Schema-qualified tables in a comma list keep their schema")
    func commaSeparatedSchemaQualified() {
        let ctx = context("SELECT * FROM sales.orders o, hr.staff s WHERE ")
        #expect(ctx.tableReferences.contains { $0.tableName == "orders" && $0.schema == "sales" && $0.alias == "o" })
        #expect(ctx.tableReferences.contains { $0.tableName == "staff" && $0.schema == "hr" && $0.alias == "s" })
    }

    @Test("AS alias in a FROM list is captured without keeping AS as the alias")
    func fromListAsAlias() {
        let ctx = context("SELECT * FROM accounts AS acc WHERE ")
        #expect(ctx.tableReferences.contains { $0.tableName == "accounts" && $0.alias == "acc" })
    }

    @Test("FROM and JOIN tables are both in scope")
    func fromAndJoinTables() {
        let ctx = context("SELECT * FROM a JOIN b ON a.id = b.id WHERE ")
        #expect(ctx.tableReferences.contains { $0.tableName == "a" })
        #expect(ctx.tableReferences.contains { $0.tableName == "b" })
    }

    @Test("DELETE FROM keeps its target table in scope")
    func deleteFromTarget() {
        let ctx = context("DELETE FROM users WHERE ")
        #expect(ctx.clauseType == .where_)
        #expect(ctx.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("A derived-table subquery does not create a phantom table reference")
    func derivedTableNoPhantom() {
        let ctx = context("SELECT * FROM (SELECT id FROM inner_t) sub WHERE ")
        #expect(ctx.clauseType == .where_)
        #expect(ctx.tableReferences.allSatisfy {
            !$0.tableName.contains("(") && $0.tableName.uppercased() != "SELECT"
        })
    }

    // MARK: - RETURNING After VALUES

    @Test("RETURNING after a VALUES list completes as RETURNING, not VALUES")
    func returningAfterValues() {
        #expect(clause("INSERT INTO t VALUES (1) RETURNING ") == .returning)
    }
}
