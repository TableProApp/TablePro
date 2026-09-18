//
//  FilterSQLGeneratorMSSQLTests.swift
//  TableProTests
//
//  Tests for FilterSQLGenerator with databaseType: .mssql
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Filter SQL Generator MSSQL")
struct FilterSQLGeneratorMSSQLTests {
    private static let mssqlDialect = SQLDialectDescriptor(
        identifierQuote: "[", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch
    )

    private let generator = FilterSQLGenerator(
        dialect: Self.mssqlDialect,
        stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(.mssql)
    )

    // MARK: - Helpers

    private func makeFilter(
        column: String = "name",
        op: FilterOperator,
        value: String = "test",
        secondValue: String? = nil
    ) -> TableFilter {
        TestFixtures.makeTableFilter(column: column, op: op, value: value, secondValue: secondValue)
    }

    // MARK: - Operator Tests

    @Test("Equal operator uses bracket-quoted column")
    func equalOperator() {
        let filter = makeFilter(op: .equal)
        let result = generator.generateCondition(from: filter)
        #expect(result == "[name] = N'test'")
    }

    @Test("Not equal operator uses bracket-quoted column")
    func notEqualOperator() {
        let filter = makeFilter(op: .notEqual)
        let result = generator.generateCondition(from: filter)
        #expect(result == "[name] != N'test'")
    }

    @Test("Contains operator generates LIKE with ESCAPE clause")
    func containsOperator() {
        let filter = makeFilter(op: .contains)
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("[name] LIKE N'%test%'") == true)
        #expect(result?.contains("ESCAPE") == true)
    }

    @Test("Not contains operator generates NOT LIKE with ESCAPE clause")
    func notContainsOperator() {
        let filter = makeFilter(op: .notContains)
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("[name] NOT LIKE N'%test%'") == true)
        #expect(result?.contains("ESCAPE") == true)
    }

    @Test("Starts with operator generates LIKE prefix pattern with ESCAPE clause")
    func startsWithOperator() {
        let filter = makeFilter(op: .startsWith)
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("[name] LIKE N'test%'") == true)
        #expect(result?.contains("ESCAPE") == true)
    }

    @Test("Ends with operator generates LIKE suffix pattern with ESCAPE clause")
    func endsWithOperator() {
        let filter = makeFilter(op: .endsWith)
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("[name] LIKE N'%test'") == true)
        #expect(result?.contains("ESCAPE") == true)
    }

    @Test("Is null operator generates IS NULL")
    func isNullOperator() {
        let filter = makeFilter(op: .isNull, value: "")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[name] IS NULL")
    }

    @Test("Is not null operator generates IS NOT NULL")
    func isNotNullOperator() {
        let filter = makeFilter(op: .isNotNull, value: "")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[name] IS NOT NULL")
    }

    @Test("Greater than operator generates correct condition")
    func greaterThanOperator() {
        let filter = makeFilter(column: "age", op: .greaterThan, value: "30")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[age] > 30")
    }

    @Test("Less than operator generates correct condition")
    func lessThanOperator() {
        let filter = makeFilter(column: "age", op: .lessThan, value: "30")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[age] < 30")
    }

    @Test("Between operator generates BETWEEN clause with numeric values unquoted")
    func betweenOperator() {
        // Numeric values are passed through without quotes by escapeValue
        let filter = makeFilter(column: "age", op: .between, value: "18", secondValue: "65")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[age] BETWEEN 18 AND 65")
    }

    @Test("Regex falls back to LIKE for MSSQL")
    func regexFallsBackToLike() {
        let filter = makeFilter(column: "email", op: .regex, value: "test")
        let result = generator.generateCondition(from: filter)
        #expect(result?.contains("LIKE") == true)
        #expect(result?.contains("REGEXP") == false)
        #expect(result?.contains("~") == false)
    }

    // MARK: - Value Escaping Tests

    @Test("Value with single quote is escaped")
    func singleQuoteEscaping() {
        let filter = makeFilter(column: "name", op: .equal, value: "O'Brien")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[name] = N'O''Brien'")
    }

    // MARK: - WHERE Clause Tests

    @Test("generateWhereClause with multiple filters joins with AND")
    func whereClauseAndMode() {
        let filters = [
            makeFilter(column: "name", op: .equal, value: "Alice"),
            makeFilter(column: "age", op: .greaterThan, value: "18")
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result.contains("WHERE"))
        #expect(result.contains("AND"))
        #expect(result.contains("[name] = N'Alice'"))
        #expect(result.contains("[age] > 18"))
    }

    @Test("generateWhereClause with OR logic mode")
    func whereClauseOrMode() {
        let filters = [
            makeFilter(column: "name", op: .equal, value: "Alice"),
            makeFilter(column: "name", op: .equal, value: "Bob")
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .or)
        #expect(result.contains("WHERE"))
        #expect(result.contains("OR"))
        #expect(result.contains("[name] = N'Alice'"))
        #expect(result.contains("[name] = N'Bob'"))
    }

    // MARK: - Identifier Quoting Tests

    @Test("MSSQL uses bracket quoting for column identifiers")
    func mssqlBracketQuoting() {
        let filter = makeFilter(column: "user_name", op: .equal, value: "test")
        let result = generator.generateCondition(from: filter)
        #expect(result?.hasPrefix("[user_name]") == true)
    }

    // MARK: - Unicode Literals

    @Test("A non-ASCII value is an nvarchar literal, so a non-Unicode collation cannot flatten it")
    func nonAsciiValueIsANationalLiteral() {
        let filter = makeFilter(op: .equal, value: "日本語メール")
        #expect(generator.generateCondition(from: filter) == "[name] = N'日本語メール'")
    }

    @Test("Every value-carrying operator writes a national literal")
    func everyValueOperatorWritesANationalLiteral() {
        let operators: [FilterOperator] = [
            .equal, .notEqual, .contains, .notContains, .startsWith, .endsWith, .regex
        ]
        for op in operators {
            let result = generator.generateCondition(from: makeFilter(op: op, value: "メール")) ?? ""
            let body = result.replacingOccurrences(of: " ESCAPE '!'", with: "")
            #expect(body.contains("N'"), "\(op) wrote no national literal")
            #expect(!body.contains(" '"), "\(op) wrote a plain literal: \(result)")
        }
    }

    @Test("An IN list prefixes every element")
    func inListPrefixesEveryElement() {
        let filter = makeFilter(op: .inList, value: "メール,alpha")
        let result = generator.generateCondition(from: filter)
        #expect(result == "[name] IN (N'メール', N'alpha')")
    }

    @Test("Numbers and NULL never take the prefix")
    func numbersAndNullAreNotPrefixed() {
        #expect(generator.generateCondition(from: makeFilter(column: "age", op: .greaterThan, value: "30"))
            == "[age] > 30")
        #expect(generator.generateCondition(from: makeFilter(op: .isNull)) == "[name] IS NULL")
    }

    @Test("A driver with no prefix is untouched")
    func otherEnginesKeepPlainLiterals() {
        let plain = FilterSQLGenerator(dialect: Self.mssqlDialect)
        #expect(plain.generateCondition(from: makeFilter(op: .equal)) == "[name] = 'test'")
    }
}
