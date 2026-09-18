//
//  FilterSQLGeneratorCaseSensitivityTests.swift
//  TableProTests
//
//  Per-dialect case-insensitive matching (#2048)
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Filter SQL Generator Case Sensitivity")
struct FilterSQLGeneratorCaseSensitivityTests {

    private static let postgresql = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator
    )

    private static let redshift = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .caseFoldFunction
    )

    private static let duckdb = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpMatches, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator
    )

    private static let mysql = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexp, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit,
        caseSensitivityStyle: .collationDefined
    )

    private static let clickhouse = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .match, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit,
        caseSensitivityStyle: .caseFoldFunction, caseFoldFunction: "lowerUTF8"
    )

    private static let oracle = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpLike, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch,
        caseSensitivityStyle: .caseFoldFunction
    )

    private static let trino = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexpLike, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .offsetFetch,
        caseSensitivityStyle: .regexFlag
    )

    private static let bigquery = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .implicit, paginationStyle: .limit,
        caseSensitivityStyle: .caseFoldFunction
    )

    private static let cassandra = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .unsupported, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit,
        caseSensitivityStyle: .unsupported
    )

    private func condition(
        _ dialect: SQLDialectDescriptor,
        _ filterOperator: FilterOperator,
        value: String = "smith",
        isCaseSensitive: Bool? = nil,
        columnTypes: [ColumnType] = []
    ) -> String? {
        let generator = FilterSQLGenerator(
            dialect: dialect, columns: ["name"], columnTypes: columnTypes
        )
        return generator.generateCondition(from: TableFilter(
            columnName: "name",
            filterOperator: filterOperator,
            value: value,
            isCaseSensitive: isCaseSensitive
        ))
    }

    // MARK: - Defaults

    @Test("Pattern operators ignore case by default")
    func testPatternDefaultsToIgnoreCase() {
        #expect(TableFilter(filterOperator: .contains).isCaseSensitive == false)
        #expect(TableFilter(filterOperator: .notContains).isCaseSensitive == false)
        #expect(TableFilter(filterOperator: .startsWith).isCaseSensitive == false)
        #expect(TableFilter(filterOperator: .endsWith).isCaseSensitive == false)
    }

    @Test("Exact, list and regex operators match case by default")
    func testExactDefaultsToMatchCase() {
        #expect(TableFilter(filterOperator: .equal).isCaseSensitive)
        #expect(TableFilter(filterOperator: .notEqual).isCaseSensitive)
        #expect(TableFilter(filterOperator: .inList).isCaseSensitive)
        #expect(TableFilter(filterOperator: .regex).isCaseSensitive)
    }

    // MARK: - ILIKE Dialects

    @Test("PostgreSQL contains ignoring case uses ILIKE")
    func testPostgresContainsUsesILike() {
        #expect(condition(Self.postgresql, .contains) == "\"name\" ILIKE '%smith%' ESCAPE '!'")
    }

    @Test("PostgreSQL contains matching case keeps LIKE")
    func testPostgresContainsMatchCase() {
        #expect(condition(Self.postgresql, .contains, isCaseSensitive: true) == "\"name\" LIKE '%smith%' ESCAPE '!'")
    }

    @Test("PostgreSQL not contains ignoring case uses NOT ILIKE")
    func testPostgresNotContainsUsesNotILike() {
        #expect(condition(Self.postgresql, .notContains) == "\"name\" NOT ILIKE '%smith%' ESCAPE '!'")
    }

    @Test("PostgreSQL starts with ignoring case anchors the pattern")
    func testPostgresStartsWith() {
        #expect(condition(Self.postgresql, .startsWith) == "\"name\" ILIKE 'smith%' ESCAPE '!'")
    }

    @Test("PostgreSQL ends with ignoring case anchors the pattern")
    func testPostgresEndsWith() {
        #expect(condition(Self.postgresql, .endsWith) == "\"name\" ILIKE '%smith' ESCAPE '!'")
    }

    @Test("DuckDB contains ignoring case uses ILIKE")
    func testDuckDBContainsUsesILike() {
        #expect(condition(Self.duckdb, .contains) == "\"name\" ILIKE '%smith%' ESCAPE '!'")
    }

    // MARK: - Case-Fold Dialects

    @Test("Oracle contains ignoring case folds both sides")
    func testOracleContainsFoldsBothSides() {
        #expect(condition(Self.oracle, .contains) == "LOWER(\"name\") LIKE LOWER('%smith%') ESCAPE '!'")
    }

    @Test("ClickHouse folds with its Unicode-aware function")
    func testClickHouseUsesLowerUtf8() {
        #expect(condition(Self.clickhouse, .contains) == "lowerUTF8(`name`) LIKE lowerUTF8('%smith%')")
    }

    @Test("Redshift folds instead of using its ASCII-only ILIKE")
    func testRedshiftFoldsInsteadOfILike() {
        #expect(condition(Self.redshift, .contains) == "LOWER(\"name\") LIKE LOWER('%smith%') ESCAPE '!'")
    }

    // MARK: - Collation-Defined And Unsupported Dialects

    @Test("MySQL emits the same SQL whichever way the row is set")
    func testMySQLIgnoresTheFlag() {
        let ignoring = condition(Self.mysql, .contains)
        let matching = condition(Self.mysql, .contains, isCaseSensitive: true)
        #expect(ignoring == "`name` LIKE '%smith%'")
        #expect(ignoring == matching)
    }

    @Test("MySQL never emits a fold function")
    func testMySQLNeverFolds() {
        #expect(condition(Self.mysql, .equal, isCaseSensitive: false) == "`name` = 'smith'")
    }

    @Test("Cassandra emits the same SQL whichever way the row is set")
    func testUnsupportedDialectIgnoresTheFlag() {
        let ignoring = condition(Self.cassandra, .contains)
        let matching = condition(Self.cassandra, .contains, isCaseSensitive: true)
        #expect(ignoring == matching)
    }

    // MARK: - Exact And List Matching

    @Test("Equals ignoring case folds both sides")
    func testEqualsIgnoringCaseFolds() {
        #expect(condition(Self.postgresql, .equal, isCaseSensitive: false) == "LOWER(\"name\") = LOWER('smith')")
    }

    @Test("Not equals ignoring case folds both sides")
    func testNotEqualsIgnoringCaseFolds() {
        #expect(condition(Self.postgresql, .notEqual, isCaseSensitive: false) == "LOWER(\"name\") != LOWER('smith')")
    }

    @Test("Equals matching case stays untouched")
    func testEqualsMatchingCaseUnchanged() {
        #expect(condition(Self.postgresql, .equal) == "\"name\" = 'smith'")
    }

    @Test("IN list ignoring case folds the column and every value")
    func testInListIgnoringCaseFolds() {
        let sql = condition(Self.postgresql, .inList, value: "a,b", isCaseSensitive: false)
        #expect(sql == "LOWER(\"name\") IN (LOWER('a'), LOWER('b'))")
    }

    @Test("A numeric column never gets a fold function wrapped around it")
    func testNumericColumnIsNeverFolded() {
        let sql = condition(
            Self.postgresql, .equal, value: "42", isCaseSensitive: false, columnTypes: [.integer(rawType: "INT")]
        )
        #expect(sql == "\"name\" = 42")
    }

    // MARK: - Regex

    @Test("PostgreSQL regex ignoring case uses the case-insensitive operator")
    func testPostgresRegexIgnoringCase() {
        #expect(condition(Self.postgresql, .regex, value: "a.*", isCaseSensitive: false) == "\"name\" ~* 'a.*'")
    }

    @Test("PostgreSQL regex matching case keeps the plain operator")
    func testPostgresRegexMatchingCase() {
        #expect(condition(Self.postgresql, .regex, value: "a.*") == "\"name\" ~ 'a.*'")
    }

    @Test("DuckDB regex ignoring case passes the flag argument")
    func testDuckDBRegexIgnoringCase() {
        let sql = condition(Self.duckdb, .regex, value: "a.*", isCaseSensitive: false)
        #expect(sql == "regexp_matches(\"name\", 'a.*', 'i')")
    }

    @Test("MySQL regex ignoring case switches to the function form")
    func testMySQLRegexIgnoringCase() {
        let sql = condition(Self.mysql, .regex, value: "a.*", isCaseSensitive: false)
        #expect(sql == "REGEXP_LIKE(`name`, 'a.*', 'i')")
    }

    @Test("ClickHouse regex ignoring case uses an inline flag")
    func testClickHouseRegexIgnoringCase() {
        let sql = condition(Self.clickhouse, .regex, value: "a.*", isCaseSensitive: false)
        #expect(sql == "match(`name`, '(?i)a.*')")
    }

    @Test("A dialect with no regex degrades to LIKE and still folds")
    func testRegexFallbackStillFolds() {
        let sql = condition(Self.bigquery, .regex, value: "a.*", isCaseSensitive: false)
        #expect(sql == "LOWER(`name`) LIKE LOWER('%a.*%')")
    }

    // MARK: - Trino

    @Test("Trino contains ignoring case uses an unanchored regex")
    func testTrinoContains() {
        #expect(condition(Self.trino, .contains) == "REGEXP_LIKE(\"name\", 'smith', 'i')")
    }

    @Test("Trino starts with ignoring case anchors at the start")
    func testTrinoStartsWith() {
        #expect(condition(Self.trino, .startsWith) == "REGEXP_LIKE(\"name\", '^smith', 'i')")
    }

    @Test("Trino ends with ignoring case anchors at the end")
    func testTrinoEndsWith() {
        #expect(condition(Self.trino, .endsWith) == "REGEXP_LIKE(\"name\", 'smith$', 'i')")
    }

    @Test("Trino equals ignoring case anchors both ends")
    func testTrinoEquals() {
        let sql = condition(Self.trino, .equal, isCaseSensitive: false)
        #expect(sql == "REGEXP_LIKE(\"name\", '^smith$', 'i')")
    }

    @Test("Trino matching case keeps plain LIKE")
    func testTrinoMatchingCaseKeepsLike() {
        let sql = condition(Self.trino, .contains, isCaseSensitive: true)
        #expect(sql == "\"name\" LIKE '%smith%' ESCAPE '!'")
    }

    @Test("Trino escapes regex metacharacters in the value")
    func testTrinoEscapesMetacharacters() {
        let sql = condition(Self.trino, .contains, value: "a.b*c")
        #expect(sql == "REGEXP_LIKE(\"name\", 'a\\.b\\*c', 'i')")
    }

    // MARK: - Wildcard Escaping

    @Test("Wildcards in the value stay escaped when ignoring case")
    func testWildcardEscapingSurvivesFolding() {
        let sql = condition(Self.postgresql, .contains, value: "50%")
        #expect(sql == "\"name\" ILIKE '%50!%%' ESCAPE '!'")
    }
}
