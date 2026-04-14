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

@Suite("Filter SQL Generator")
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`email` REGEXP '^[a-z]+@'")
    }

    // MARK: - Value Type Detection

    @Test("NULL literal generates unquoted NULL")
    func testNullLiteral() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "NULL",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = NULL")
    }

    @Test("TRUE literal generates 1 for MySQL")
    func testTrueLiteralMySQL() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "TRUE",
            secondValue: nil,
            isSelected: true,
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
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`active` = 0")
    }

    @Test("Numeric value generates unquoted number")
    func testNumericValue() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "age",
            filterOperator: .equal,
            value: "42",
            secondValue: nil,
            isSelected: true,
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
            isSelected: true,
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
                isSelected: true,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isSelected: true,
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
                isSelected: true,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isSelected: true,
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
                isSelected: true,
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
                isSelected: true,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
            isEnabled: true,
            rawSQL: "age > 18"
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(age > 18)")
    }

    // MARK: - Identifier Quoting Per DB Type

    @Test("MySQL uses backtick quoting")
    func testMySQLQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'test'")
    }

    @Test("PostgreSQL uses double quote quoting")
    func testPostgreSQLQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isSelected: true,
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
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'test'")
    }

    @Test("MariaDB uses backtick quoting")
    func testMariaDBQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` LIKE 'test\\\\_\\\\%%'")
    }

    // MARK: - Regex Per DB Type

    @Test("MySQL regex uses REGEXP")
    func testMySQLRegex() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "email",
            filterOperator: .regex,
            value: "^[a-z]+@",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`email` REGEXP '^[a-z]+@'")
    }

    @Test("PostgreSQL regex uses tilde operator")
    func testPostgreSQLRegex() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "email",
            filterOperator: .regex,
            value: "^[a-z]+@",
            secondValue: nil,
            isSelected: true,
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
            isSelected: true,
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
                isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
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
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"active\" = FALSE")
    }

    // MARK: - Redshift Tests

    @Test("Redshift uses double-quote identifier quoting")
    func testRedshiftQuoting() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .equal,
            value: "test",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"name\" = 'test'")
    }

    @Test("Redshift regex uses tilde operator")
    func testRedshiftRegex() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "email",
            filterOperator: .regex,
            value: "^[a-z]+@",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"email\" ~ '^[a-z]+@'")
    }

    @Test("Redshift TRUE literal generates TRUE")
    func testTrueLiteralRedshift() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "TRUE",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"active\" = TRUE")
    }

    @Test("Redshift FALSE literal generates FALSE")
    func testFalseLiteralRedshift() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "active",
            filterOperator: .equal,
            value: "FALSE",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "\"active\" = FALSE")
    }

    @Test("Redshift LIKE uses ESCAPE clause")
    func testRedshiftLikeEscape() {
        let generator = FilterSQLGenerator(dialect: Self.postgresqlDialect)
        let filter = TableFilter(
            id: UUID(),
            columnName: "name",
            filterOperator: .contains,
            value: "50%",
            secondValue: nil,
            isSelected: true,
            isEnabled: true,
            rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("ESCAPE") == true)
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
                isSelected: true,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isSelected: true,
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
                isSelected: true,
                isEnabled: true,
                rawSQL: nil
            ),
            TableFilter(
                id: UUID(),
                columnName: "status",
                filterOperator: .equal,
                value: "active",
                secondValue: nil,
                isSelected: true,
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
            value: "NULL", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NULL")
    }

    @Test("Equal with null (lowercase) generates IS NULL")
    func testEqualNullLowercaseGeneratesIsNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "name", filterOperator: .equal,
            value: "null", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NULL")
    }

    @Test("Not equal with NULL value generates IS NOT NULL")
    func testNotEqualNullGeneratesIsNotNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "name", filterOperator: .notEqual,
            value: "NULL", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` IS NOT NULL")
    }

    @Test("Equal with regular string value unchanged")
    func testEqualRegularStringUnchanged() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "name", filterOperator: .equal,
            value: "hello", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`name` = 'hello'")
    }

    // MARK: - IN/NOT IN with NULL Values (Fix D)

    @Test("IN list containing NULL generates OR IS NULL")
    func testInListWithNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "status", filterOperator: .inList,
            value: "1, NULL, 3", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(`status` IN (1, 3) OR `status` IS NULL)")
    }

    @Test("NOT IN list containing NULL generates AND IS NOT NULL")
    func testNotInListWithNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "status", filterOperator: .notInList,
            value: "1, NULL, 3", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "(`status` NOT IN (1, 3) AND `status` IS NOT NULL)")
    }

    @Test("IN list without NULL unchanged")
    func testInListWithoutNullUnchanged() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "id", filterOperator: .inList,
            value: "1, 2, 3", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`id` IN (1, 2, 3)")
    }

    @Test("IN list with only NULL generates IS NULL")
    func testInListOnlyNull() {
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)
        let filter = TableFilter(
            id: UUID(), columnName: "status", filterOperator: .inList,
            value: "NULL", secondValue: nil, isSelected: true, isEnabled: true, rawSQL: nil
        )
        let result = generator.generateCondition(from: filter)
        #expect(result == "`status` IS NULL")
    }
}
