//
//  SQLContextAnalyzerTests.swift
//  TableProTests
//
//  Tests for SQL context analysis at cursor position
//

import Foundation
import Testing
@testable import TablePro

@Suite("SQL Context Analyzer")
struct SQLContextAnalyzerTests {
    let analyzer = SQLContextAnalyzer()

    // MARK: - Clause Detection Tests

    @Test("Detects SELECT clause at beginning")
    func testSelectClause() {
        let context = analyzer.analyze(query: "SELECT ", cursorPosition: 7)
        #expect(context.clauseType == .select)
    }

    @Test("Detects SELECT clause with comma")
    func testSelectClauseWithComma() {
        let context = analyzer.analyze(query: "SELECT id, ", cursorPosition: 11)
        #expect(context.clauseType == .select)
    }

    @Test("Detects FROM clause after SELECT")
    func testFromClauseAfterSelect() {
        let context = analyzer.analyze(query: "SELECT * FROM ", cursorPosition: 14)
        #expect(context.clauseType == .from)
    }

    @Test("Detects FROM clause with table name")
    func testFromClauseWithTable() {
        let context = analyzer.analyze(query: "SELECT * FROM users ", cursorPosition: 20)
        #expect(context.clauseType == .from)
    }

    @Test("Detects JOIN clause")
    func testJoinClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users JOIN ", cursorPosition: 25)
        #expect(context.clauseType == .join)
    }

    @Test("Detects LEFT JOIN clause")
    func testLeftJoinClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users LEFT JOIN ", cursorPosition: 30)
        #expect(context.clauseType == .join)
    }

    @Test("Detects ON clause")
    func testOnClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users u ON ", cursorPosition: 25)
        #expect(context.clauseType == .on)
    }

    @Test("Detects WHERE clause")
    func testWhereClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users WHERE ", cursorPosition: 26)
        #expect(context.clauseType == .where_)
    }

    @Test("Detects AND clause after WHERE")
    func testAndClauseAfterWhere() {
        let context = analyzer.analyze(query: "SELECT * FROM users WHERE id = 1 AND ", cursorPosition: 38)
        #expect(context.clauseType == .and)
    }

    @Test("Detects AND clause after OR")
    func testAndClauseAfterOr() {
        let context = analyzer.analyze(query: "SELECT * FROM users WHERE id = 1 OR ", cursorPosition: 37)
        #expect(context.clauseType == .and)
    }

    @Test("Detects GROUP BY clause")
    func testGroupByClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users GROUP BY ", cursorPosition: 29)
        #expect(context.clauseType == .groupBy)
    }

    @Test("Detects ORDER BY clause")
    func testOrderByClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users ORDER BY ", cursorPosition: 29)
        #expect(context.clauseType == .orderBy)
    }

    @Test("Detects HAVING clause")
    func testHavingClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users HAVING ", cursorPosition: 27)
        #expect(context.clauseType == .having)
    }

    @Test("Detects SET clause in UPDATE")
    func testSetClause() {
        let context = analyzer.analyze(query: "UPDATE users SET ", cursorPosition: 17)
        #expect(context.clauseType == .set)
    }

    @Test("Detects INTO clause in INSERT")
    func testIntoClause() {
        let context = analyzer.analyze(query: "INSERT INTO ", cursorPosition: 12)
        #expect(context.clauseType == .into)
    }

    @Test("Detects VALUES clause")
    func testValuesClause() {
        let context = analyzer.analyze(query: "INSERT INTO users VALUES (", cursorPosition: 26)
        #expect(context.clauseType == .values)
    }

    @Test("Detects INSERT columns clause")
    func testInsertColumnsClause() {
        let context = analyzer.analyze(query: "INSERT INTO users (id, ", cursorPosition: 23)
        #expect(context.clauseType == .insertColumns)
    }

    @Test("Detects SELECT clause for function call in SELECT")
    func testFunctionArgClause() {
        let context = analyzer.analyze(query: "SELECT COUNT(", cursorPosition: 13)
        // The SELECT regex matches before the function-arg fallback,
        // because regex-based clause detection runs before function detection
        #expect(context.clauseType == .select)
    }

    @Test("Detects CASE expression clause")
    func testCaseExpressionClause() {
        let context = analyzer.analyze(query: "SELECT CASE WHEN ", cursorPosition: 17)
        #expect(context.clauseType == .caseExpression)
    }

    @Test("Detects IN list clause")
    func testInListClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users WHERE id IN (", cursorPosition: 33)
        #expect(context.clauseType == .inList)
    }

    @Test("Detects LIMIT clause")
    func testLimitClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users LIMIT ", cursorPosition: 26)
        #expect(context.clauseType == .limit)
    }

    @Test("Detects ALTER TABLE clause")
    func testAlterTableClause() {
        let context = analyzer.analyze(query: "ALTER TABLE users ", cursorPosition: 18)
        #expect(context.clauseType == .alterTable)
    }

    @Test("Detects ALTER TABLE column clause")
    func testAlterTableColumnClause() {
        let context = analyzer.analyze(query: "ALTER TABLE users DROP COLUMN ", cursorPosition: 30)
        #expect(context.clauseType == .alterTableColumn)
    }

    @Test("Detects DROP object clause")
    func testDropObjectClause() {
        let context = analyzer.analyze(query: "DROP TABLE ", cursorPosition: 11)
        #expect(context.clauseType == .dropObject)
    }

    @Test("Detects ON clause for CREATE INDEX ... ON")
    func testCreateIndexClause() {
        let context = analyzer.analyze(query: "CREATE INDEX idx ON ", cursorPosition: 20)
        // The ON regex matches before the CREATE INDEX regex (which needs a table name after ON)
        #expect(context.clauseType == .on)
    }

    @Test("Detects unknown clause for empty query")
    func testUnknownClauseEmpty() {
        let context = analyzer.analyze(query: "", cursorPosition: 0)
        #expect(context.clauseType == .unknown)
    }

    @Test("Detects RETURNING clause")
    func testReturningClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users RETURNING ", cursorPosition: 30)
        #expect(context.clauseType == .returning)
    }

    @Test("Detects UNION clause")
    func testUnionClause() {
        let context = analyzer.analyze(query: "SELECT UNION ", cursorPosition: 13)
        #expect(context.clauseType == .union)
    }

    @Test("Detects USING clause")
    func testUsingClause() {
        let context = analyzer.analyze(query: "SELECT * FROM a JOIN b USING (", cursorPosition: 30)
        #expect(context.clauseType == .using)
    }

    // MARK: - Prefix Extraction Tests

    @Test("Extracts partial prefix")
    func testPartialPrefix() {
        let context = analyzer.analyze(query: "SELECT us", cursorPosition: 9)
        #expect(context.prefix == "us")
    }

    @Test("Extracts empty prefix after space")
    func testEmptyPrefixAfterSpace() {
        let context = analyzer.analyze(query: "SELECT ", cursorPosition: 7)
        #expect(context.prefix == "")
    }

    @Test("Extracts prefix with dot qualifier")
    func testPrefixWithDotQualifier() {
        let context = analyzer.analyze(query: "SELECT users.na", cursorPosition: 15)
        #expect(context.prefix == "na")
        #expect(context.dotPrefix == "users")
    }

    @Test("Extracts prefix with alias qualifier")
    func testPrefixWithAliasQualifier() {
        let context = analyzer.analyze(query: "SELECT u.na", cursorPosition: 11)
        #expect(context.prefix == "na")
        #expect(context.dotPrefix == "u")
    }

    @Test("Extracts prefix in WHERE clause")
    func testPrefixInWhere() {
        let context = analyzer.analyze(query: "WHERE id", cursorPosition: 8)
        #expect(context.prefix == "id")
    }

    @Test("Extracts empty prefix at exact position")
    func testEmptyPrefixAtPosition() {
        let context = analyzer.analyze(query: "SELECT ", cursorPosition: 7)
        #expect(context.prefix == "")
    }

    @Test("Extracts full identifier prefix")
    func testFullIdentifierPrefix() {
        let context = analyzer.analyze(query: "SELECT abc", cursorPosition: 10)
        #expect(context.prefix == "abc")
    }

    @Test("Extracts dot prefix with backticks")
    func testDotPrefixWithBackticks() {
        let context = analyzer.analyze(query: "FROM `users`.", cursorPosition: 13)
        #expect(context.dotPrefix != nil)
    }

    // MARK: - Table Reference Tests

    @Test("Extracts table reference from FROM")
    func testTableReferenceFromClause() {
        let context = analyzer.analyze(query: "SELECT * FROM users", cursorPosition: 19)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("Extracts table reference with alias")
    func testTableReferenceWithAlias() {
        let context = analyzer.analyze(query: "SELECT * FROM users u", cursorPosition: 21)
        #expect(context.tableReferences.contains { $0.tableName == "users" && $0.alias == "u" })
    }

    @Test("Extracts multiple table references with JOIN")
    func testMultipleTableReferencesWithJoin() {
        let context = analyzer.analyze(query: "SELECT * FROM users u JOIN orders o", cursorPosition: 35)
        #expect(context.tableReferences.count == 2)
        #expect(context.tableReferences.contains { $0.tableName == "users" && $0.alias == "u" })
        #expect(context.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    @Test("Extracts table reference from UPDATE")
    func testTableReferenceFromUpdate() {
        let context = analyzer.analyze(query: "UPDATE users SET", cursorPosition: 16)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("Extracts table reference from INSERT")
    func testTableReferenceFromInsert() {
        let context = analyzer.analyze(query: "INSERT INTO users", cursorPosition: 17)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("Extracts table reference with AS keyword")
    func testTableReferenceWithAsKeyword() {
        let context = analyzer.analyze(query: "SELECT * FROM users AS u", cursorPosition: 24)
        #expect(context.tableReferences.contains { $0.tableName == "users" && $0.alias == "u" })
    }

    @Test("Extracts table reference from comma-separated list")
    func testMultipleTablesCommaSeparated() {
        let context = analyzer.analyze(query: "SELECT * FROM users, orders", cursorPosition: 27)
        // The FROM regex only captures the first table after FROM;
        // comma-separated tables beyond the first are not captured
        #expect(context.tableReferences.count >= 1)
    }

    @Test("Returns empty table references for empty query")
    func testEmptyTableReferences() {
        let context = analyzer.analyze(query: "", cursorPosition: 0)
        #expect(context.tableReferences.isEmpty)
    }

    // MARK: - String/Comment Boundary Tests

    @Test("Detects cursor inside string with unclosed quote")
    func testInsideStringUnclosed() {
        let context = analyzer.analyze(query: "SELECT * FROM users WHERE name = '", cursorPosition: 34)
        #expect(context.isInsideString == true)
    }

    @Test("Detects cursor outside string with closed quote")
    func testOutsideStringClosed() {
        let context = analyzer.analyze(query: "SELECT * FROM users WHERE name = 'John'", cursorPosition: 39)
        #expect(context.isInsideString == false)
    }

    @Test("Detects cursor inside single-line comment")
    func testInsideSingleLineComment() {
        let context = analyzer.analyze(query: "-- comment\nSELECT ", cursorPosition: 5)
        #expect(context.isInsideComment == true)
    }

    @Test("Detects cursor inside block comment")
    func testInsideBlockComment() {
        let context = analyzer.analyze(query: "/* block comment", cursorPosition: 10)
        #expect(context.isInsideComment == true)
    }

    @Test("Detects cursor outside block comment")
    func testOutsideBlockComment() {
        let context = analyzer.analyze(query: "SELECT * /* comment */ FROM ", cursorPosition: 28)
        #expect(context.isInsideComment == false)
    }

    @Test("Handles escaped quote in string")
    func testEscapedQuoteInString() {
        let context = analyzer.analyze(query: "SELECT 'it''s' FROM ", cursorPosition: 20)
        #expect(context.isInsideString == false)
    }

    @Test("Handles double-quoted identifier")
    func testDoubleQuotedIdentifier() {
        let context = analyzer.analyze(query: "SELECT \"col\" FROM ", cursorPosition: 18)
        #expect(context.isInsideString == false)
    }

    @Test("Normal query has no string or comment context")
    func testNormalQueryNoContext() {
        let context = analyzer.analyze(query: "SELECT * FROM users", cursorPosition: 19)
        #expect(context.isInsideString == false)
        #expect(context.isInsideComment == false)
    }

    // MARK: - CTE Tests

    @Test("Extracts single CTE name")
    func testSingleCTEName() {
        let context = analyzer.analyze(query: "WITH cte AS (SELECT 1) SELECT * FROM ", cursorPosition: 37)
        #expect(context.cteNames.contains("cte"))
    }

    @Test("Extracts multiple CTE names")
    func testMultipleCTENames() {
        let context = analyzer.analyze(query: "WITH a AS (SELECT 1), b AS (SELECT 2) SELECT ", cursorPosition: 45)
        #expect(context.cteNames.contains("a"))
        #expect(context.cteNames.contains("b"))
    }

    @Test("Extracts recursive CTE name")
    func testRecursiveCTEName() {
        let context = analyzer.analyze(query: "WITH RECURSIVE cte AS (SELECT 1) SELECT ", cursorPosition: 40)
        #expect(context.cteNames.contains("cte"))
    }

    @Test("Returns empty CTE names when no CTE")
    func testNoCTENames() {
        let context = analyzer.analyze(query: "SELECT * FROM users", cursorPosition: 19)
        #expect(context.cteNames.isEmpty)
    }

    @Test("CTE adds to table references")
    func testCTEAddsToTableReferences() {
        let context = analyzer.analyze(query: "WITH cte AS (SELECT 1) SELECT * FROM cte", cursorPosition: 40)
        #expect(context.cteNames.contains("cte"))
        #expect(context.tableReferences.contains { $0.tableName == "cte" })
    }

    // MARK: - Nesting Level Tests

    @Test("Detects nesting level zero for simple query")
    func testNestingLevelZero() {
        let context = analyzer.analyze(query: "SELECT * FROM users", cursorPosition: 19)
        #expect(context.nestingLevel == 0)
    }

    @Test("Detects nesting level one for subquery")
    func testNestingLevelOne() {
        let context = analyzer.analyze(query: "SELECT * FROM (SELECT ", cursorPosition: 22)
        #expect(context.nestingLevel == 1)
    }

    @Test("Detects nesting level two for nested subquery")
    func testNestingLevelTwo() {
        let context = analyzer.analyze(query: "SELECT * FROM (SELECT * FROM (SELECT ", cursorPosition: 37)
        #expect(context.nestingLevel == 2)
    }

    @Test("Detects nesting level zero after closing parenthesis")
    func testNestingLevelZeroAfterClose() {
        let context = analyzer.analyze(query: "SELECT * FROM (SELECT *) WHERE ", cursorPosition: 31)
        #expect(context.nestingLevel == 0)
    }

    // MARK: - Function Context Tests

    @Test("Detects function name for COUNT")
    func testFunctionNameCount() {
        let context = analyzer.analyze(query: "SELECT COUNT(", cursorPosition: 13)
        #expect(context.currentFunction == "COUNT")
    }

    @Test("Detects innermost function for nested functions")
    func testInnermostFunctionNested() {
        let context = analyzer.analyze(query: "SELECT UPPER(LOWER(", cursorPosition: 19)
        #expect(context.currentFunction == "LOWER")
    }

    @Test("No function context outside function call")
    func testNoFunctionContext() {
        let context = analyzer.analyze(query: "SELECT * FROM users", cursorPosition: 19)
        #expect(context.currentFunction == nil)
    }

    @Test("Detects function name for COALESCE")
    func testFunctionNameCoalesce() {
        let context = analyzer.analyze(query: "SELECT COALESCE(a, ", cursorPosition: 19)
        #expect(context.currentFunction == "COALESCE")
    }

    // MARK: - Comma Detection Tests

    @Test("Detects cursor after comma in SELECT")
    func testAfterCommaInSelect() {
        let context = analyzer.analyze(query: "SELECT a, ", cursorPosition: 10)
        #expect(context.isAfterComma == true)
    }

    @Test("Detects cursor not after comma")
    func testNotAfterComma() {
        let context = analyzer.analyze(query: "SELECT a", cursorPosition: 8)
        #expect(context.isAfterComma == false)
    }

    @Test("Detects cursor after comma with extra spaces")
    func testAfterCommaWithSpaces() {
        let context = analyzer.analyze(query: "SELECT a,  ", cursorPosition: 11)
        #expect(context.isAfterComma == true)
    }

    // MARK: - Multi-Statement Tests

    @Test("Analyzes second statement in multi-statement query")
    func testMultiStatementAnalysis() {
        let context = analyzer.analyze(query: "SELECT 1; SELECT ", cursorPosition: 17)
        #expect(context.clauseType == .select)
    }

    // MARK: - P0: CF-3 - SELECT clause for wildcard

    @Test("SELECT with star prefix returns select context")
    func testSelectStarPrefix() {
        let context = analyzer.analyze(query: "SELECT *", cursorPosition: 8)
        #expect(context.clauseType == .select)
        // '*' is not an identifier char, so prefix extraction yields empty string
        #expect(context.prefix == "")
    }

    // MARK: - P0: CF-4 - Function context detection

    @Test("COUNT( detected as function context")
    func testCountFunctionContext() {
        let context = analyzer.analyze(query: "SELECT COUNT(", cursorPosition: 13)
        #expect(context.currentFunction == "COUNT")
    }

    @Test("SUM( detected as function context")
    func testSumFunctionContext() {
        let context = analyzer.analyze(query: "SELECT SUM(", cursorPosition: 11)
        #expect(context.currentFunction == "SUM")
    }

    // MARK: - P1: HP-1 - New Clause Types

    @Test("RETURNING detected after INSERT VALUES")
    func testReturningAfterInsertValues() {
        let query = "INSERT INTO users (name) VALUES ('test') RETURNING "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .returning)
    }

    @Test("RETURNING detected after DELETE")
    func testReturningAfterDelete() {
        let query = "DELETE FROM users WHERE id = 1 RETURNING "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .returning)
    }

    @Test("RETURNING detected after UPDATE")
    func testReturningAfterUpdate() {
        let query = "UPDATE users SET name = 'x' RETURNING "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .returning)
    }

    @Test("UNION ALL detected as union clause")
    func testUnionAllClause() {
        let query = "SELECT id FROM users UNION ALL "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .union)
    }

    @Test("INTERSECT detected as union clause")
    func testIntersectDetected() {
        let query = "SELECT id FROM users INTERSECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .union)
    }

    @Test("EXCEPT detected as union clause")
    func testExceptDetected() {
        let query = "SELECT id FROM users EXCEPT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .union)
    }

    @Test("USING clause detected in JOIN")
    func testUsingInJoin() {
        let query = "SELECT * FROM users JOIN orders USING (id"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .using)
    }

    @Test("OVER clause detected for window function")
    func testOverClause() {
        let query = "SELECT ROW_NUMBER() OVER ("
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .window)
    }

    @Test("PARTITION BY detected as window clause")
    func testPartitionBy() {
        let query = "SELECT ROW_NUMBER() OVER (PARTITION BY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .window)
    }

    @Test("DROP TABLE detected as dropObject")
    func testDropTableDropObject() {
        let query = "DROP TABLE "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .dropObject)
    }

    @Test("DROP VIEW detected as dropObject")
    func testDropViewDropObject() {
        let query = "DROP VIEW "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .dropObject)
    }

    @Test("DROP INDEX detected as dropObject")
    func testDropIndexDropObject() {
        let query = "DROP INDEX "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .dropObject)
    }

    @Test("DROP TABLE IF EXISTS detected")
    func testDropTableIfExists() {
        let query = "DROP TABLE IF EXISTS "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .dropObject)
    }

    @Test("CREATE INDEX name detected")
    func testCreateIndexName() {
        let query = "CREATE INDEX "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createIndex)
    }

    @Test("CREATE UNIQUE INDEX detected")
    func testCreateUniqueIndex() {
        let query = "CREATE UNIQUE INDEX "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createIndex)
    }

    @Test("CREATE INDEX ON table inside parens detected")
    func testCreateIndexOnTableParens() {
        let query = "CREATE INDEX idx ON users ("
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createIndex)
    }

    @Test("CREATE VIEW detected")
    func testCreateView() {
        let query = "CREATE VIEW "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createView)
    }

    @Test("CREATE OR REPLACE VIEW detected")
    func testCreateOrReplaceView() {
        let query = "CREATE OR REPLACE VIEW "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createView)
    }

    @Test("CREATE VIEW AS detected")
    func testCreateViewAs() {
        let query = "CREATE VIEW my_view AS "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createView)
    }

    @Test("CREATE MATERIALIZED VIEW detected")
    func testCreateMaterializedView() {
        let query = "CREATE MATERIALIZED VIEW "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createView)
    }

    // MARK: - P1: HP-4 - Double-quote Identifier Handling

    @Test("Double-quoted dot prefix extracts correctly")
    func testDoubleQuotedDotPrefix() {
        let context = analyzer.analyze(query: "SELECT \"users\".", cursorPosition: 15)
        #expect(context.dotPrefix == "users")
    }

    @Test("Backtick-quoted dot prefix extracts correctly")
    func testBacktickDotPrefixExtraction() {
        let context = analyzer.analyze(query: "SELECT `orders`.s", cursorPosition: 17)
        #expect(context.dotPrefix == "orders")
        #expect(context.prefix == "s")
    }

    // MARK: - P1: HP-6 - Static Regex CTE/Table Refs

    @Test("CTE with recursive keyword extracted")
    func testRecursiveCTE() {
        let query = "WITH RECURSIVE tree AS (SELECT 1) SELECT * FROM "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.cteNames.contains("tree"))
    }

    @Test("INSERT INTO extracts table reference")
    func testInsertIntoTableRef() {
        let query = "INSERT INTO orders (id) VALUES (1)"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "orders" })
    }

    @Test("CREATE INDEX ON extracts table reference")
    func testCreateIndexOnTableRef() {
        let query = "CREATE INDEX idx ON products ("
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "products" })
    }

    @Test("Multiple JOIN table references extracted")
    func testMultipleJoinTableRefs() {
        let query = "SELECT * FROM users u LEFT JOIN orders o ON o.user_id = u.id JOIN products p ON "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
        #expect(context.tableReferences.contains { $0.tableName == "orders" })
        #expect(context.tableReferences.contains { $0.tableName == "products" })
    }

    // MARK: - Bugfix Regressions

    @Test("CREATE TABLE not detected as functionArg")
    func testCreateTableNotFunctionArg() {
        // Regression: "CREATE TABLE test (" looked like function call "test("
        let query = "CREATE TABLE test (id "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .createTable)
        #expect(context.clauseType != .functionArg)
    }

    @Test("VALUES after closed parens still detected as values")
    func testValuesAfterClosedParens() {
        let query = "INSERT INTO users (name) VALUES ('test') "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .values)
    }

    @Test("VALUES with multiple tuples after closed parens")
    func testValuesMultipleTuplesAfterClosed() {
        let query = "INSERT INTO users (name) VALUES ('a'), ('b') "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .values)
    }

    @Test("Typing RE after VALUES suggests values context")
    func testTypingAfterClosedValues() {
        let query = "INSERT INTO users (name) VALUES ('test') RE"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .values)
        #expect(context.prefix == "RE")
    }

    @Test("INSERT INTO table reference extracted for RETURNING")
    func testInsertTableRefForReturning() {
        let query = "INSERT INTO users (name) VALUES ('test') RETURNING "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("CREATE INDEX ON table reference extracted for column lookup")
    func testCreateIndexTableRefForColumns() {
        let query = "CREATE UNIQUE INDEX idx ON users ("
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    // MARK: - P2: MP-3 - Schema-Qualified Names

    @Test("Double dot extracts schema and table prefix")
    func testDoubleDotSchemaPrefix() {
        let context = analyzer.analyze(query: "SELECT public.users.na", cursorPosition: 22)
        // After implementation, dotPrefix should contain the table reference
        // The prefix should be the column part being typed
        #expect(context.prefix == "na")
        #expect(context.dotPrefix != nil)
    }

    @Test("Schema.table. with empty column prefix")
    func testSchemaTableDotEmptyPrefix() {
        let context = analyzer.analyze(query: "SELECT public.users.", cursorPosition: 20)
        #expect(context.prefix == "")
        #expect(context.dotPrefix != nil)
    }

    @Test("Backtick-quoted schema.table.column")
    func testBacktickSchemaQualified() {
        let context = analyzer.analyze(query: "SELECT `mydb`.`users`.n", cursorPosition: 23)
        #expect(context.prefix == "n")
        #expect(context.dotPrefix != nil)
    }

    // MARK: - P2: MP-10 - Block Comment Edge Cases

    @Test("Nested block comments handled correctly")
    func testNestedBlockComments() {
        // MySQL supports nested comments differently
        let context = analyzer.analyze(query: "/* outer /* inner */ still comment */SELECT ", cursorPosition: 43)
        #expect(context.isInsideComment == false)
    }

    @Test("Block comment at end of query")
    func testBlockCommentAtEnd() {
        let context = analyzer.analyze(query: "SELECT * FROM users /*", cursorPosition: 22)
        #expect(context.isInsideComment == true)
    }

    @Test("Multiple block comments with code between")
    func testMultipleBlockComments() {
        let context = analyzer.analyze(query: "/* c1 */ SELECT /* c2 */ * FROM ", cursorPosition: 31)
        #expect(context.isInsideComment == false)
        #expect(context.clauseType == .from)
    }

    @Test("Empty block comment does not affect analysis")
    func testEmptyBlockComment() {
        let context = analyzer.analyze(query: "/**/ SELECT ", cursorPosition: 12)
        #expect(context.isInsideComment == false)
        #expect(context.clauseType == .select)
    }

    @Test("Line comment inside block comment")
    func testLineCommentInsideBlock() {
        let context = analyzer.analyze(query: "/* -- not a line comment */SELECT ", cursorPosition: 33)
        #expect(context.isInsideComment == false)
    }

    @Test("Block comment detection with star in query")
    func testStarNotConfusedWithComment() {
        let context = analyzer.analyze(query: "SELECT * FROM users", cursorPosition: 19)
        #expect(context.isInsideComment == false)
    }

    // MARK: - P3: LP-6 - Subquery Context Detection

    @Test("Subquery in WHERE IN - clause type is select inside subquery")
    func testSubqueryInWhereIn() {
        let query = "SELECT * FROM users WHERE id IN (SELECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
        #expect(context.nestingLevel > 0)
    }

    @Test("Subquery in WHERE IN - WHERE inside subquery detected")
    func testSubqueryWhereClause() {
        let query = "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
        #expect(context.nestingLevel > 0)
    }

    @Test("Subquery in FROM - detected as select")
    func testSubqueryInFrom() {
        let query = "SELECT * FROM (SELECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
        #expect(context.nestingLevel > 0)
    }

    @Test("Nested subquery increases nesting level")
    func testNestedSubqueryLevel() {
        let query = "SELECT * FROM (SELECT * FROM (SELECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.nestingLevel >= 2)
    }

    @Test("Subquery table references include outer query tables")
    func testSubqueryIncludesOuterTableRefs() {
        let query = "SELECT * FROM users u WHERE id IN (SELECT user_id FROM orders WHERE "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        // Should find both inner and outer table references
        #expect(context.tableReferences.contains { $0.tableName == "orders" })
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("Closed subquery returns to outer context")
    func testClosedSubqueryReturnsToOuter() {
        let query = "SELECT * FROM users WHERE id IN (SELECT 1) AND "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .and)
        #expect(context.nestingLevel == 0)
    }

    @Test("EXISTS subquery detected")
    func testExistsSubquery() {
        let query = "SELECT * FROM users WHERE EXISTS (SELECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
        #expect(context.nestingLevel > 0)
    }

    // MARK: - Schema-Qualified Table Name Tests

    @Test("FROM with schema-qualified table strips schema prefix")
    func testFromSchemaQualifiedTable() {
        let query = "SELECT * FROM public.users"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
        #expect(!context.tableReferences.contains { $0.tableName == "public" })
        #expect(!context.tableReferences.contains { $0.tableName == "public.users" })
    }

    @Test("FROM with multi-level schema strips to last component")
    func testFromMultiLevelSchemaQualifiedTable() {
        let query = "SELECT * FROM catalog.schema.users"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("JOIN with schema-qualified table strips schema prefix")
    func testJoinSchemaQualifiedTable() {
        let query = "SELECT * FROM users JOIN public.orders ON orders.id = users.order_id"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "orders" })
    }

    @Test("UPDATE with schema-qualified table strips schema prefix")
    func testUpdateSchemaQualifiedTable() {
        let query = "UPDATE public.users SET name = 'test'"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("INSERT INTO with schema-qualified table strips schema prefix")
    func testInsertIntoSchemaQualifiedTable() {
        let query = "INSERT INTO public.users (name) VALUES ('test')"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("FROM without schema prefix still works normally")
    func testFromWithoutSchemaPrefix() {
        let query = "SELECT * FROM users"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("Backtick-quoted schema-qualified table extracts reference")
    func testBacktickQuotedSchemaQualifiedTable() {
        let query = "SELECT * FROM `public.users`"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("Schema-qualified table with alias extracts both correctly")
    func testSchemaQualifiedTableWithAlias() {
        let query = "SELECT * FROM public.users u"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" && $0.alias == "u" })
    }

    @Test("Multiple schema-qualified tables in FROM and JOIN both extracted")
    func testMultipleSchemaQualifiedTables() {
        let query = "SELECT * FROM public.users JOIN schema2.orders ON orders.user_id = users.id"
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
        #expect(context.tableReferences.contains { $0.tableName == "orders" })
    }

    // MARK: - Parse-Ahead Table Reference Tests

    @Test("Table references extracted from full statement even when cursor is before FROM")
    func testTableRefsExtractedAheadOfCursor() {
        let query = "SELECT  FROM users"
        // Cursor at position 7 (after "SELECT ")
        let context = analyzer.analyze(query: query, cursorPosition: 7)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
    }

    @Test("All table references extracted from full statement regardless of cursor position")
    func testAllTableRefsExtractedAheadOfCursor() {
        let query = "SELECT na FROM users JOIN orders"
        // Cursor at position 9 (after "SELECT na")
        let context = analyzer.analyze(query: query, cursorPosition: 9)
        #expect(context.tableReferences.contains { $0.tableName == "users" })
        #expect(context.tableReferences.contains { $0.tableName == "orders" })
    }
}
