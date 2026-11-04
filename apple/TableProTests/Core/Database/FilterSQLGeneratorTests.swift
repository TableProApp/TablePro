//
//  FilterSQLGeneratorTests.swift
//  TableProTests
//
//  Tests for FilterSQLGenerator
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

struct FilterSQLGeneratorTests {

    private static let mysqlDialect = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexp, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit
    )

    private static let postgresqlDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit
    )

    private static let sqliteDialect = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .limit
    )

    private static let clickhouseDialect = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .match, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit
    )

    private static let duckdbDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpMatches, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit
    )

    private static let oracleDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpLike, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch,
        offsetFetchOrderBy: "ORDER BY 1"
    )

    private static let trinoDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpLike, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch,
        offsetFetchOrderBy: ""
    )

    private static let snowflakeDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpLike, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        requiresBackslashEscaping: true
    )

    // MARK: - Per-Operator Tests (MySQL)

    @Test("Equal operator generates correct condition")
    func testEqualOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'test'")
    }

    @Test("Not equal operator generates correct condition")
    func testNotEqualOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .notEqual,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` != 'test'")
    }

    @Test("Contains operator generates correct LIKE condition")
    func testContainsOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .contains,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE '%test%'")
    }

    @Test("Not contains operator generates correct NOT LIKE condition")
    func testNotContainsOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .notContains,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` NOT LIKE '%test%'")
    }

    @Test("Starts with operator generates correct LIKE condition")
    func testStartsWithOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .startsWith,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE 'test%'")
    }

    @Test("Ends with operator generates correct LIKE condition")
    func testEndsWithOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .endsWith,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE '%test'")
    }

    @Test("Greater than operator generates correct condition")
    func testGreaterThanOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .greaterThan,
            value: "18",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`age` > 18")
    }

    @Test("Greater or equal operator generates correct condition")
    func testGreaterOrEqualOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .greaterOrEqual,
            value: "18",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`age` >= 18")
    }

    @Test("Less than operator generates correct condition")
    func testLessThanOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .lessThan,
            value: "65",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`age` < 65")
    }

    @Test("Less or equal operator generates correct condition")
    func testLessOrEqualOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .lessOrEqual,
            value: "65",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`age` <= 65")
    }

    @Test("Is null operator generates correct condition")
    func testIsNullOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .isNull,
            value: "",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NULL")
    }

    @Test("Is not null operator generates correct condition")
    func testIsNotNullOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .isNotNull,
            value: "",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NOT NULL")
    }

    @Test("Is empty operator generates correct condition")
    func testIsEmptyOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .isEmpty,
            value: "",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(`name` IS NULL OR `name` = '')")
    }

    @Test("Is not empty operator generates correct condition")
    func testIsNotEmptyOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .isNotEmpty,
            value: "",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(`name` IS NOT NULL AND `name` != '')")
    }

    @Test("In list operator generates correct IN condition")
    func testInListOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "status",
            filterOperator: .inList,
            value: "a, b, c",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`status` IN ('a', 'b', 'c')")
    }

    @Test("Not in list operator generates correct NOT IN condition")
    func testNotInListOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "status",
            filterOperator: .notInList,
            value: "a, b, c",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`status` NOT IN ('a', 'b', 'c')")
    }

    @Test("Between operator generates correct BETWEEN condition")
    func testBetweenOperator() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .between,
            value: "18",
            secondValue: "65",
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`age` BETWEEN 18 AND 65")
    }

    @Test("Regex operator generates correct REGEXP condition for MySQL")
    func testRegexOperatorMySQL() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "email",
            filterOperator: .regex,
            value: "^[a-z]+@",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`email` REGEXP '^[a-z]+@'")
    }

    // MARK: - Value Type Detection

    @Test("TRUE literal generates 1 for MySQL")
    func testTrueLiteralMySQL() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "TRUE",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`active` = 1")
    }

    @Test("FALSE literal generates 0 for MySQL")
    func testFalseLiteralMySQL() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "FALSE",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`active` = 0")
    }

    @Test("Numeric value without a known column type falls back to the shape heuristic")
    func testNumericValue() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .equal,
            value: "42",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`age` = 42")
    }

    @Test("String value generates quoted string")
    func testStringValue() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "hello",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'hello'")
    }

    // MARK: - WHERE Composition

    @Test("AND mode with 2 filters generates AND clause")
    func testAndMode() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "age",
                filterOperator: .greaterThan,
                value: "18",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result == "WHERE `age` > 18 AND `status` = 'active'")
    }

    @Test("OR mode with 2 filters generates OR clause")
    func testOrMode() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "age",
                filterOperator: .greaterThan,
                value: "18",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .or)
        #expect(result == "WHERE `age` > 18 OR `status` = 'active'")
    }

    @Test("Empty filters generates empty string")
    func testEmptyFilters() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters: [TableFilter] = []
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result == "")
    }

    @Test("Single filter generates no AND/OR")
    func testSingleFilter() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "age",
                filterOperator: .greaterThan,
                value: "18",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result == "WHERE `age` > 18")
    }

    @Test("Invalid filter is skipped")
    func testInvalidFilterSkipped() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "",
                filterOperator: .equal,
                value: "test",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result == "WHERE `status` = 'active'")
    }

    // MARK: - SQL Injection Protection

    @Test("Single quote in value is escaped")
    func testSingleQuoteEscaping() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "O'Brien",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'O''Brien'")
    }

    @Test("Column with special chars is quoted properly")
    func testColumnQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "user name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`user name` = 'test'")
    }

    @Test("Raw SQL mode generates condition from rawSQL")
    func testRawSQLMode() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "__RAW__",
            filterOperator: .equal,
            value: "",
            secondValue: nil,
            isEnabled: true,
            rawSQL: "age > 18"
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(age > 18)")
    }

    @Test("Raw SQL rejects destructive statement injection", arguments: [
        "1=1; DROP TABLE users",
        "1=1; DELETE FROM users",
        "1=1; INSERT INTO users VALUES (1)",
        "1=1; UPDATE users SET admin=1",
        "1=1; ALTER TABLE users ADD COLUMN pwned TEXT",
        "1=1; CREATE TABLE evil (id INT)",
        "1=1; TRUNCATE TABLE users",
        "1=1; GRANT ALL ON *.* TO attacker",
        "1=1; REVOKE ALL ON *.* FROM user",
        "1=1; EXEC xp_cmdshell 'whoami'",
        "1=1; EXECUTE sp_executesql 'SELECT 1'",
        "1=1; drop table users"
    ])
    func testRawSQLRejectsDestructiveStatements(input: String) {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(columnName: "__RAW__", rawSQL: input)
        #expect(generator.generateCondition(from: filter) == nil)
    }

    @Test("Raw SQL rejects comment injection", arguments: [
        "1=1 -- always true",
        "1=1 /* comment */"
    ])
    func testRawSQLRejectsCommentInjection(input: String) {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(columnName: "__RAW__", rawSQL: input)
        #expect(generator.generateCondition(from: filter) == nil)
    }

    @Test("Raw SQL allows legitimate WHERE conditions", arguments: [
        ("age > 18 AND status = 'active'", "(age > 18 AND status = 'active')"),
        ("id IN (SELECT id FROM other)", "(id IN (SELECT id FROM other))"),
        ("YEAR(created_at) = 2024", "(YEAR(created_at) = 2024)"),
        ("status = 'semi;colon'", "(status = 'semi;colon')"),
        ("data->>'key' = 'value'", "(data->>'key' = 'value')")
    ])
    func testRawSQLAllowsLegitimateConditions(input: String, expected: String) {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(columnName: "__RAW__", rawSQL: input)
        #expect(generator.generateCondition(from: filter) == expected)
    }

    // MARK: - Identifier Quoting Per DB Type

    @Test("PostgreSQL uses double quote quoting")
    func testPostgreSQLQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"name\" = 'test'")
    }

    @Test("SQLite uses backtick quoting")
    func testSQLiteQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.sqliteDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'test'")
    }

    // MARK: - LIKE Wildcard Escaping

    @Test("Contains with percent in value escapes percent")
    func testPercentEscaping() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .contains,
            value: "50%",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE '%50\\\\%%'")
    }

    @Test("Contains with underscore in value escapes underscore")
    func testUnderscoreEscaping() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .contains,
            value: "test_value",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE '%test\\\\_value%'")
    }

    @Test("Starts with escapes special chars")
    func testStartsWithSpecialChars() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .startsWith,
            value: "test_%",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE 'test\\\\_\\\\%%'")
    }

    // MARK: - Regex Per DB Type

    @Test("PostgreSQL regex uses tilde operator")
    func testPostgreSQLRegex() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "email",
            filterOperator: .regex,
            value: "^[a-z]+@",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"email\" ~ '^[a-z]+@'")
    }

    @Test("SQLite regex falls back to LIKE")
    func testSQLiteRegex() {
        let generator = FilterSQLGenerator(dialect: Self.sqliteDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "email",
            filterOperator: .regex,
            value: "test",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`email` LIKE '%test%'")
    }

    // MARK: - Preview SQL

    @Test("Preview SQL includes SELECT FROM WHERE LIMIT")
    func testPreviewSQL() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "age",
                filterOperator: .greaterThan,
                value: "18",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generatePreviewSQL(tableName: "users", filters: filters, limit: 1000)
        #expect(result.contains("SELECT * FROM"))
        #expect(result.contains("users"))
        #expect(result.contains("WHERE `age` > 18"))
        #expect(result.contains("LIMIT 1000"))
    }

    @Test("Preview SQL without filters has no WHERE")
    func testPreviewSQLNoFilters() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filters: [TableFilter] = []
        let result = generator.generatePreviewSQL(tableName: "users", filters: filters, limit: 1000)
        #expect(result.contains("SELECT * FROM"))
        #expect(result.contains("users"))
        #expect(!result.contains("WHERE"))
        #expect(result.contains("LIMIT 1000"))
    }

    @Test("Preview SQL qualifies the table with the schema")
    func testPreviewSQLWithSchema() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let result = generator.generatePreviewSQL(
            tableName: "users", schemaName: "sales", filters: [], limit: 1_000
        )
        #expect(result.contains("SELECT * FROM `sales`.`users`"))
    }

    @Test("Preview SQL with an empty schema stays unqualified")
    func testPreviewSQLWithEmptySchema() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let result = generator.generatePreviewSQL(
            tableName: "users", schemaName: "", filters: [], limit: 1_000
        )
        #expect(result.contains("SELECT * FROM `users`"))
    }

    @Test("Trino paging emits OFFSET before FETCH FIRST with no synthetic ORDER BY")
    func testPreviewSQLTrinoOffsetFetch() {
        let generator = FilterSQLGenerator(dialect: Self.trinoDialect)
        let result = generator.generatePreviewSQL(
            tableName: "pseudo_columns", schemaName: "jdbc", filters: [], limit: 1_000
        )
        #expect(result.contains("OFFSET 0 ROWS FETCH NEXT 1000 ROWS ONLY"))
        #expect(!result.contains("LIMIT"))
        #expect(!result.contains("ORDER BY"))
    }

    @Test("Oracle paging keeps its default ORDER BY before OFFSET and FETCH FIRST")
    func testPreviewSQLOracleOffsetFetch() {
        let generator = FilterSQLGenerator(dialect: Self.oracleDialect)
        let result = generator.generatePreviewSQL(tableName: "users", filters: [], limit: 1_000)
        #expect(result.contains("ORDER BY 1 OFFSET 0 ROWS FETCH NEXT 1000 ROWS ONLY"))
        #expect(!result.contains("LIMIT"))
    }

    // MARK: - Edge Cases

    @Test("Between with missing secondValue returns nil")
    func testBetweenMissingSecondValue() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .between,
            value: "18",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == nil)
    }

    @Test("InList with empty value returns nil")
    func testInListEmptyValue() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "status",
            filterOperator: .inList,
            value: "",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == nil)
    }

    @Test("TRUE literal generates TRUE for PostgreSQL")
    func testTrueLiteralPostgreSQL() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "TRUE",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"active\" = TRUE")
    }

    @Test("FALSE literal generates FALSE for PostgreSQL")
    func testFalseLiteralPostgreSQL() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "FALSE",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"active\" = FALSE")
    }

    // MARK: - Redshift Tests

    @Test("Redshift LIKE uses a non-backslash ESCAPE clause")
    func testRedshiftLikeEscape() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .contains,
            value: "50%",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("ESCAPE '!'") == true)
        #expect(result?.contains("ESCAPE '\\'") == false)
    }

    @Test("Explicit-dialect LIKE escapes a literal exclamation mark in the value")
    func testExplicitLikeEscapesExclamation() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .contains,
            value: "a!b",
            secondValue: nil,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("a!!b") == true)
    }

    @Test("Redshift AND mode with 2 filters generates AND clause")
    func testRedshiftAndMode() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "age",
                filterOperator: .greaterThan,
                value: "18",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result == "WHERE \"age\" > 18 AND \"status\" = 'active'")
    }

    @Test("Redshift OR mode with 2 filters generates OR clause")
    func testRedshiftOrMode() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filters = [
            TableFilter(
                id: UUID(),
                columnName: "age",
                filterOperator: .greaterThan,
                value: "18",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isEnabled: true,
                rawSQL: nil
            )
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .or)
        #expect(result == "WHERE \"age\" > 18 OR \"status\" = 'active'")
    }

    // MARK: - NULL Value Auto-Conversion (Fix A)

    @Test("Equal with NULL value generates IS NULL")
    func testEqualNullGeneratesIsNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "name", filterOperator: .equal,
            value: "NULL", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NULL")
    }

    @Test("Equal with null (lowercase) generates IS NULL")
    func testEqualNullLowercaseGeneratesIsNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "name", filterOperator: .equal,
            value: "null", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NULL")
    }

    @Test("Not equal with NULL value generates IS NOT NULL")
    func testNotEqualNullGeneratesIsNotNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "name", filterOperator: .notEqual,
            value: "NULL", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NOT NULL")
    }

    // MARK: - IN/NOT IN with NULL Values (Fix D)

    @Test("IN list containing NULL generates OR IS NULL")
    func testInListWithNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "status", filterOperator: .inList,
            value: "1, NULL, 3", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(`status` IN (1, 3) OR `status` IS NULL)")
    }

    @Test("NOT IN list containing NULL generates AND IS NOT NULL")
    func testNotInListWithNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "status", filterOperator: .notInList,
            value: "1, NULL, 3", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(`status` NOT IN (1, 3) AND `status` IS NOT NULL)")
    }

    @Test("IN list without NULL unchanged")
    func testInListWithoutNullUnchanged() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "id", filterOperator: .inList,
            value: "1, 2, 3", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`id` IN (1, 2, 3)")
    }

    @Test("IN list with only NULL generates IS NULL")
    func testInListOnlyNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "status", filterOperator: .inList,
            value: "NULL", secondValue: nil, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`status` IS NULL")
    }

    // MARK: - Literal Escaping

    private func condition(
        _ dialect: SQLDialectDescriptor, _ filterOperator: FilterOperator, _ value: String, column: String = "code"
    ) -> String? {
        FilterSQLGenerator(dialect: dialect).generateCondition(from: TableFilter(
            columnName: column, filterOperator: filterOperator, value: value, isCaseSensitive: true
        ))
    }

    // Snowflake takes an ESCAPE clause for LIKE and still reads `\'` inside a literal as a quote.
    @Test("A Snowflake filter value doubles its backslash, whatever the operator", arguments: [
        (FilterOperator.equal, #""CODE" = '\\''; DROP TABLE AUDIT_LOG; --'"#),
        (.inList, #""CODE" IN ('\\''; DROP TABLE AUDIT_LOG; --')"#),
        (.contains, #""CODE" LIKE '%\\''; DROP TABLE AUDIT!_LOG; --%' ESCAPE '!'"#),
        (.startsWith, #""CODE" LIKE '\\''; DROP TABLE AUDIT!_LOG; --%' ESCAPE '!'"#),
        (.regex, #"REGEXP_LIKE("CODE", '\\''; DROP TABLE AUDIT_LOG; --')"#)
    ])
    func snowflakeDoublesBackslash(filterOperator: FilterOperator, expected: String) {
        #expect(condition(Self.snowflakeDialect, filterOperator, #"\'; DROP TABLE AUDIT_LOG; --"#, column: "CODE") == expected)
    }

    @Test("A Snowflake LIKE pattern reads a backslash as a character, not as its escape")
    func snowflakeLikeBackslashIsLiteral() {
        #expect(condition(Self.snowflakeDialect, .endsWith, #"C:\temp\"#) == #""code" LIKE '%C:\\temp\\' ESCAPE '!'"#)
    }

    @Test("The LIKE a regex falls back to doubles a backslash where the engine reads it as an escape")
    func regexFallbackDoublesBackslash() {
        let implicitWithoutRegex = SQLDialectDescriptor(
            identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
            regexSyntax: .unsupported, booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .implicit, paginationStyle: .limit
        )
        #expect(condition(implicitWithoutRegex, .regex, #"\' OR 1=1 -- "#) == #"`code` LIKE '%\\'' OR 1=1 -- %'"#)
        #expect(condition(Self.sqliteDialect, .regex, #"\' OR 1=1 -- "#) == #"`code` LIKE '%\'' OR 1=1 -- %'"#)
    }

    @Test("A MySQL LIKE keeps a backslash literal through the string and the pattern")
    func mysqlLikeBackslash() {
        #expect(condition(Self.mysqlDialect, .contains, #"a\b%"#) == #"`code` LIKE '%a\\\\b\\%%'"#)
    }

    // standard_conforming_strings off makes PostgreSQL read `\'` as a quote, so the descriptor's answer let the value
    // close the literal.
    @Test("A PostgreSQL session that reads backslash escapes gets the backslash doubled")
    func postgresSessionWithBackslashEscapes() {
        let escaping = PluginSessionLexicalState(
            determined: [.backslashEscapesInSingleQuotes], enabled: [.backslashEscapesInSingleQuotes]
        )
        let conforming = PluginSessionLexicalState(determined: [.backslashEscapesInSingleQuotes], enabled: [])
        let filter = TableFilter(columnName: "code", filterOperator: .equal, value: #"\' OR 1=1 --"#, isCaseSensitive: true)
        let rendered: (PluginSessionLexicalState) -> String? = { session in
            FilterSQLGenerator(
                dialect: Self.postgresqlDialect,
                databaseType: .postgresql,
                stringEscapes: SQLLexicalResolver.stringEscapes(for: .postgresql, session: session)
            ).generateCondition(from: filter)
        }
        #expect(rendered(escaping) == #""code" = '\\'' OR 1=1 --'"#)
        #expect(rendered(conforming) == #""code" = '\'' OR 1=1 --'"#)
    }

    // NO_BACKSLASH_ESCAPES leaves MySQL's LIKE with no escape character, so the pattern names one.
    @Test("A MySQL session without backslash escapes names the LIKE escape")
    func mysqlSessionWithoutBackslashEscapesNamesTheLikeEscape() {
        let session = PluginSessionLexicalState(determined: [.backslashEscapesInSingleQuotes], enabled: [])
        let generator = FilterSQLGenerator(
            dialect: Self.mysqlDialect,
            databaseType: .mysql,
            stringEscapes: SQLLexicalResolver.stringEscapes(for: .mysql, session: session)
        )
        let like = generator.generateCondition(from: TableFilter(
            columnName: "code", filterOperator: .contains, value: #"50%\"#, isCaseSensitive: true
        ))
        #expect(like == #"`code` LIKE '%50\%\\%' ESCAPE '\'"#)
    }

    // A combining mark or a Prepend scalar joins the quote or backslash into one grapheme cluster.
    @Test("A quote or backslash fused with its neighbour is still escaped", arguments: [
        ("x'\u{0301} OR 1=1 --", #"`code` = 'x''"# + "\u{0301}" + #" OR 1=1 --'"#),
        ("\u{0600}\\' OR 1=1 --", "`code` = '\u{0600}" + #"\\'' OR 1=1 --'"#)
    ])
    func fusedQuoteIsEscaped(value: String, expected: String) {
        #expect(condition(Self.mysqlDialect, .equal, value) == expected)
    }

    @Test("A quote fused with a combining mark is escaped in a LIKE pattern")
    func fusedQuoteInLikeIsEscaped() {
        #expect(
            condition(Self.postgresqlDialect, .contains, "x'\u{0301})")
                == "\"code\" LIKE '%x''\u{0301})%' ESCAPE '!'"
        )
    }

    // MARK: - LIKE Pattern Byte Limit

    // Cloudflare D1's shape: SQLite's LIKE, which rejects a pattern longer than 50 bytes.
    private static let cappedPatternDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .collationDefined,
        textCastTypeName: nil, functionNamesAreCaseInsensitive: true,
        likePatternByteLimit: 50
    )

    private static let uncappedPatternDialect = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .collationDefined,
        textCastTypeName: nil, functionNamesAreCaseInsensitive: true
    )

    @Test("A pattern at the byte limit stays the LIKE it was", arguments: [
        (FilterOperator.contains, String(repeating: "a", count: 48)),
        (.notContains, String(repeating: "a", count: 48)),
        (.startsWith, String(repeating: "a", count: 49)),
        (.endsWith, String(repeating: "a", count: 49)),
        (.contains, String(repeating: "a", count: 46) + "%"),
        (.contains, String(repeating: "é", count: 24))
    ])
    func patternAtTheLimitKeepsLike(filterOperator: FilterOperator, value: String) throws {
        let capped = try #require(condition(Self.cappedPatternDialect, filterOperator, value))
        #expect(capped == condition(Self.uncappedPatternDialect, filterOperator, value))
        #expect(capped.contains(" LIKE "))
    }

    @Test("A pattern past the byte limit matches the value as a substring", arguments: [
        (FilterOperator.contains, "instr(LOWER(\"code\"), LOWER('V')) > 0"),
        (.notContains, "instr(LOWER(\"code\"), LOWER('V')) = 0"),
        (.startsWith, "instr(LOWER(\"code\"), LOWER('V')) = 1"),
        (.endsWith, "substr(LOWER(\"code\"), -length('V')) = LOWER('V')")
    ])
    func patternPastTheLimitMatchesASubstring(filterOperator: FilterOperator, expected: String) {
        let value = String(repeating: "a", count: 50)
        #expect(
            condition(Self.cappedPatternDialect, filterOperator, value)
                == expected.replacingOccurrences(of: "V", with: value)
        )
    }

    @Test("The bytes counted are the pattern as sent, wildcard escapes and multi-byte letters included", arguments: [
        String(repeating: "a", count: 49),
        String(repeating: "a", count: 47) + "%",
        String(repeating: "é", count: 25)
    ])
    func limitCountsThePatternAsSent(value: String) throws {
        let capped = try #require(condition(Self.cappedPatternDialect, .contains, value))
        #expect(capped.hasPrefix("instr("))
    }

    @Test("A long value past the limit is a plain literal, with no LIKE escape")
    func substringLiteralKeepsWildcardsLiteral() {
        let value = String(repeating: "a", count: 45) + "50%_'s!"
        let literal = "'" + String(repeating: "a", count: 45) + "50%_''s!'"
        #expect(
            condition(Self.cappedPatternDialect, .contains, value)
                == "instr(LOWER(\"code\"), LOWER(\(literal))) > 0"
        )
    }

    @Test("A regex an engine without one turns into LIKE matches a substring past the byte limit")
    func regexFallbackPastTheLimitMatchesASubstring() {
        let value = String(repeating: "a", count: 49)
        #expect(condition(Self.cappedPatternDialect, .regex, value) == "instr(LOWER(\"code\"), LOWER('\(value)')) > 0")
        #expect(condition(Self.cappedPatternDialect, .regex, "abc") == condition(Self.uncappedPatternDialect, .regex, "abc"))
    }

    @Test("A dialect with no byte limit keeps LIKE for any length")
    func uncappedDialectKeepsLike() {
        let value = String(repeating: "a", count: 200)
        #expect(
            condition(Self.uncappedPatternDialect, .contains, value)
                == "\"code\" LIKE '%\(value)%' ESCAPE '!'"
        )
    }
}
