//
//  FilterSQLGeneratorColumnTypeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Filter SQL Generator Column Types")
struct FilterSQLGeneratorColumnTypeTests {

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

    private static func generator(
        columns: [String],
        types: [ColumnType],
        dialect: SQLDialectDescriptor = mysqlDialect
    ) -> FilterSQLGenerator {
        FilterSQLGenerator(dialect: dialect, columns: columns, columnTypes: types)
    }

    private static func condition(
        column: String,
        type: ColumnType?,
        op: FilterOperator = .equal,
        value: String,
        secondValue: String? = nil,
        dialect: SQLDialectDescriptor = mysqlDialect
    ) -> String? {
        let generator = FilterSQLGenerator(
            dialect: dialect,
            columns: type == nil ? [] : [column],
            columnTypes: type.map { [$0] } ?? []
        )
        let filter = TestFixtures.makeTableFilter(
            column: column, op: op, value: value, secondValue: secondValue
        )
        return generator.generateCondition(from: filter)
    }

    @Test("A numeric-looking value on a text column is quoted")
    func textColumnQuotesNumericShapedValue() {
        let result = Self.condition(column: "code", type: .text(rawType: "VARCHAR(20)"), value: "68")
        #expect(result == "`code` = '68'")
    }

    @Test("A numeric-looking value on an integer column stays unquoted")
    func integerColumnKeepsNumericUnquoted() {
        let result = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "68")
        #expect(result == "`id` = 68")
    }

    @Test("A non-numeric value on an integer column is quoted")
    func integerColumnQuotesNonNumericValue() {
        let result = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "68a")
        #expect(result == "`id` = '68a'")
    }

    @Test("Scientific notation is unquoted on a decimal column and quoted on an integer column")
    func decimalColumnAcceptsScientificNotation() {
        let decimal = Self.condition(column: "amount", type: .decimal(rawType: "DECIMAL"), value: "1e5")
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "1e5")
        #expect(decimal == "`amount` = 1e5")
        #expect(integer == "`id` = '1e5'")
    }

    @Test("An enum column quotes a numeric-looking value so it never matches by ordinal")
    func enumColumnQuotesNumericShapedValue() {
        let result = Self.condition(
            column: "status", type: .enumType(rawType: "ENUM", values: ["draft", "1"]), value: "1"
        )
        #expect(result == "`status` = '1'")
    }

    @Test("A boolean column maps synonyms to the dialect boolean literal")
    func booleanColumnMapsSynonyms() {
        let numericStyle = Self.condition(column: "active", type: .boolean(rawType: "TINYINT(1)"), value: "yes")
        let wordStyle = Self.condition(
            column: "active", type: .boolean(rawType: "BOOLEAN"), value: "on", dialect: Self.postgresqlDialect
        )
        #expect(numericStyle == "`active` = 1")
        #expect(wordStyle == "\"active\" = TRUE")
    }

    @Test("TRUE on a non-boolean column is a quoted string, not a boolean literal")
    func trueLiteralOnNonBooleanColumnIsQuoted() {
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), value: "TRUE")
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "TRUE")
        #expect(text == "`code` = 'TRUE'")
        #expect(integer == "`id` = 'TRUE'")
    }

    @Test("NULL typed into a text column filters for the literal text")
    func nullLiteralOnTextColumnIsNotPromoted() {
        let result = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), value: "NULL")
        #expect(result == "`code` = 'NULL'")
    }

    @Test("NULL typed into a non-text column still becomes IS NULL")
    func nullLiteralOnNonTextColumnIsPromoted() {
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "NULL")
        let notEqual = Self.condition(
            column: "id", type: .integer(rawType: "INT"), op: .notEqual, value: "null"
        )
        #expect(integer == "`id` IS NULL")
        #expect(notEqual == "`id` IS NOT NULL")
    }

    @Test("An unknown column type keeps the legacy shape heuristic")
    func unknownColumnTypeFallsBackToShapeHeuristic() {
        let numeric = Self.condition(column: "age", type: nil, value: "42")
        let null = Self.condition(column: "age", type: nil, value: "NULL")
        let boolean = Self.condition(column: "age", type: nil, value: "TRUE")
        #expect(numeric == "`age` = 42")
        #expect(null == "`age` IS NULL")
        #expect(boolean == "`age` = 1")
    }

    @Test("A filter on a column missing from the result set falls back to the shape heuristic")
    func unmappedColumnFallsBackToShapeHeuristic() {
        let generator = Self.generator(columns: ["id"], types: [.integer(rawType: "INT")])
        let filter = TestFixtures.makeTableFilter(column: "code", op: .equal, value: "68")
        #expect(generator.generateCondition(from: filter) == "`code` = 68")
    }

    @Test("Comparison operators use the column type")
    func comparisonOperatorsUseColumnType() {
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), op: .greaterThan, value: "68")
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), op: .lessOrEqual, value: "68")
        #expect(text == "`code` > '68'")
        #expect(integer == "`id` <= 68")
    }

    @Test("BETWEEN applies the column type to both bounds")
    func betweenUsesColumnTypeForBothBounds() {
        let result = Self.condition(
            column: "code", type: .text(rawType: "VARCHAR"), op: .between, value: "10", secondValue: "68"
        )
        #expect(result == "`code` BETWEEN '10' AND '68'")
    }

    @Test("IN quotes each element by the column type")
    func inListQuotesEachElementByColumnType() {
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), op: .inList, value: "68, 70")
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), op: .inList, value: "68, 70")
        #expect(text == "`code` IN ('68', '70')")
        #expect(integer == "`id` IN (68, 70)")
    }

    @Test("IN keeps a literal NULL string on a text column")
    func inListKeepsLiteralNullOnTextColumn() {
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), op: .inList, value: "68, NULL")
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), op: .inList, value: "68, NULL")
        #expect(text == "`code` IN ('68', 'NULL')")
        #expect(integer == "(`id` IN (68) OR `id` IS NULL)")
    }

    @Test("IS EMPTY drops the empty string comparison on a non-text column")
    func isEmptyDropsEmptyStringComparisonOnNonTextColumn() {
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), op: .isEmpty, value: "")
        let notEmpty = Self.condition(column: "id", type: .integer(rawType: "INT"), op: .isNotEmpty, value: "")
        #expect(integer == "`id` IS NULL")
        #expect(notEmpty == "`id` IS NOT NULL")
    }

    @Test("IS EMPTY keeps the empty string comparison on a text column and when the type is unknown")
    func isEmptyKeepsEmptyStringComparisonOnTextColumn() {
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), op: .isEmpty, value: "")
        let unknown = Self.condition(column: "code", type: nil, op: .isEmpty, value: "")
        #expect(text == "(`code` IS NULL OR `code` = '')")
        #expect(unknown == "(`code` IS NULL OR `code` = '')")
    }

    @Test("A quoted value on a text column still escapes single quotes")
    func textColumnEscapesQuotes() {
        let result = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), value: "O'Brien")
        #expect(result == "`code` = 'O''Brien'")
    }

    @Test("Leading zeros stay unquoted on an integer column and quoted on a text column")
    func leadingZerosFollowColumnType() {
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "0068")
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), value: "0068")
        #expect(integer == "`id` = 0068")
        #expect(text == "`code` = '0068'")
    }

    @Test("A date column quotes a numeric-looking value")
    func dateColumnQuotesNumericShapedValue() {
        let result = Self.condition(column: "created_at", type: .timestamp(rawType: "TIMESTAMP"), value: "2026")
        #expect(result == "`created_at` = '2026'")
    }

    @Test("The first column wins when a result set repeats a column name")
    func duplicateColumnNamesResolveToTheFirst() {
        let generator = Self.generator(
            columns: ["code", "code"], types: [.text(rawType: "VARCHAR"), .integer(rawType: "INT")]
        )
        let filter = TestFixtures.makeTableFilter(column: "code", op: .equal, value: "68")
        #expect(generator.generateCondition(from: filter) == "`code` = '68'")
    }

    @Test("A short columnTypes array does not misalign the remaining columns")
    func shortColumnTypesArrayDegradesGracefully() {
        let generator = Self.generator(columns: ["id", "code"], types: [.integer(rawType: "INT")])
        let idFilter = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "68")
        let codeFilter = TestFixtures.makeTableFilter(column: "code", op: .equal, value: "68")
        #expect(generator.generateCondition(from: idFilter) == "`id` = 68")
        #expect(generator.generateCondition(from: codeFilter) == "`code` = 68")
    }

    @Test("Whitespace around a value is trimmed before the type decides quoting")
    func valueIsTrimmedBeforeQuoting() {
        let integer = Self.condition(column: "id", type: .integer(rawType: "INT"), value: "  68  ")
        let text = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), value: "  68  ")
        #expect(integer == "`id` = 68")
        #expect(text == "`code` = '68'")
    }

    @Test("LIKE operators always quote their pattern regardless of column type")
    func likeOperatorsAlwaysQuote() {
        let contains = Self.condition(column: "id", type: .integer(rawType: "INT"), op: .contains, value: "68")
        let startsWith = Self.condition(column: "code", type: .text(rawType: "VARCHAR"), op: .startsWith, value: "68")
        #expect(contains == "`id` LIKE '%68%'")
        #expect(startsWith == "`code` LIKE '68%'")
    }

    // MARK: - Text cast for pattern matching

    private static let castingPostgres = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator, textCastTypeName: "TEXT"
    )

    private static func castingCondition(
        column: String,
        type: ColumnType?,
        op: FilterOperator,
        value: String,
        isCaseSensitive: Bool? = nil
    ) -> String? {
        let generator = FilterSQLGenerator(
            dialect: castingPostgres,
            columns: type == nil ? [] : [column],
            columnTypes: type.map { [$0] } ?? []
        )
        let filter = TableFilter(
            columnName: column, filterOperator: op, value: value, isCaseSensitive: isCaseSensitive
        )
        return generator.generateCondition(from: filter)
    }

    @Test("Contains on a uuid column is cast to text before ILIKE")
    func uuidContainsIsCastToText() {
        let result = Self.castingCondition(
            column: "id", type: .text(rawType: "uuid"), op: .contains, value: "ab"
        )
        #expect(result == "CAST(\"id\" AS TEXT) ILIKE '%ab%' ESCAPE '!'")
    }

    @Test("Contains on a character column is not cast")
    func varcharContainsKeepsTheColumn() {
        for rawType in ["varchar", "character varying(255)", "text", "bpchar", "citext", "name"] {
            let result = Self.castingCondition(
                column: "name", type: .text(rawType: rawType), op: .contains, value: "ab"
            )
            #expect(result == "\"name\" ILIKE '%ab%' ESCAPE '!'", "\(rawType)")
        }
    }

    @Test("Starts with on an integer column is cast to text")
    func integerStartsWithIsCastToText() {
        let result = Self.castingCondition(
            column: "id", type: .integer(rawType: "integer"), op: .startsWith, value: "68"
        )
        #expect(result == "CAST(\"id\" AS TEXT) ILIKE '68%' ESCAPE '!'")
    }

    @Test("Ignoring case on an enum folds the cast, matching case keeps the enum comparison")
    func enumEqualsFoldsOnlyTheCast() {
        let folded = Self.castingCondition(
            column: "status", type: .enumType(rawType: "ENUM(mood)", values: nil),
            op: .equal, value: "happy", isCaseSensitive: false
        )
        let exact = Self.castingCondition(
            column: "status", type: .enumType(rawType: "ENUM(mood)", values: nil),
            op: .equal, value: "happy"
        )
        #expect(folded == "LOWER(CAST(\"status\" AS TEXT)) = LOWER('happy')")
        #expect(exact == "\"status\" = 'happy'")
    }

    @Test("Regex on a timestamp column is cast to text")
    func timestampRegexIsCastToText() {
        let result = Self.castingCondition(
            column: "created_at", type: .timestamp(rawType: "timestamptz"), op: .regex, value: "^2024"
        )
        #expect(result == "CAST(\"created_at\" AS TEXT) ~ '^2024'")
    }

    @Test("Is empty on a uuid column compares the cast, on an array only null")
    func isEmptyCastsOrFallsBackToNull() {
        let uuid = Self.castingCondition(
            column: "id", type: .text(rawType: "uuid"), op: .isEmpty, value: ""
        )
        let array = Self.castingCondition(
            column: "tags", type: .array(rawType: "text[]", element: .text(rawType: "text")),
            op: .isEmpty, value: ""
        )
        #expect(uuid == "(\"id\" IS NULL OR CAST(\"id\" AS TEXT) = '')")
        #expect(array == "\"tags\" IS NULL")
    }

    @Test("Contains on an array column searches its text form")
    func arrayContainsIsCastToText() {
        let result = Self.castingCondition(
            column: "tags", type: .array(rawType: "text[]", element: .text(rawType: "text")),
            op: .contains, value: "red"
        )
        #expect(result == "CAST(\"tags\" AS TEXT) ILIKE '%red%' ESCAPE '!'")
    }

    @Test("In list ignoring case on a uuid column folds the cast")
    func uuidInListIgnoringCaseFoldsTheCast() {
        let result = Self.castingCondition(
            column: "id", type: .text(rawType: "uuid"), op: .inList, value: "a, b", isCaseSensitive: false
        )
        #expect(result == "LOWER(CAST(\"id\" AS TEXT)) IN (LOWER('a'), LOWER('b'))")
    }

    @Test("A column of unknown type is cast, because a cast is valid on every column")
    func unknownColumnTypeIsCast() {
        let result = Self.castingCondition(column: "id", type: nil, op: .contains, value: "ab")
        #expect(result == "CAST(\"id\" AS TEXT) ILIKE '%ab%' ESCAPE '!'")
    }

    @Test("In list ignoring case on an integer column keeps the numbers unfolded")
    func integerInListIgnoringCaseIsNotFolded() {
        let result = Self.castingCondition(
            column: "id", type: .integer(rawType: "integer"), op: .inList, value: "1, 2", isCaseSensitive: false
        )
        let mixed = Self.castingCondition(
            column: "id", type: .integer(rawType: "integer"), op: .inList, value: "1, x", isCaseSensitive: false
        )
        #expect(result == "\"id\" IN (1, 2)")
        #expect(mixed == "\"id\" IN (1, 'x')")
    }

    @Test("A dialect without a text cast type leaves a non-text column alone")
    func dialectWithoutCastTypeDoesNotCast() {
        let result = Self.condition(
            column: "id", type: .text(rawType: "uuid"), op: .contains, value: "ab",
            dialect: Self.postgresqlDialect
        )
        #expect(result == "\"id\" LIKE '%ab%' ESCAPE '!'")
    }
}
