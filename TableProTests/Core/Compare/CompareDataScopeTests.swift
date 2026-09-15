//
//  CompareDataScopeTests.swift
//  TableProTests
//
//  What one table contributes to a data comparison: its key, its excluded columns, its filters and
//  its row limit, the SQL those turn into, and how a saved setup reads back.
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

private final class ScopeQuotingDriver: PluginDatabaseDriver, @unchecked Sendable {
    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

private enum ScopeDialect {
    static func make(
        paginationStyle: SQLDialectDescriptor.PaginationStyle = .limit,
        offsetFetchOrderBy: String = "ORDER BY (SELECT NULL)",
        autoLimitStyle: AutoLimitStyle = .limit
    ) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            paginationStyle: paginationStyle,
            offsetFetchOrderBy: offsetFetchOrderBy,
            autoLimitStyle: autoLimitStyle,
            textCastTypeName: nil
        )
    }
}

final class DataTableScopeTests: XCTestCase {

    // MARK: - Filters

    func testAWhitespaceOnlyFilterIsNoFilter() {
        let scope = DataTableScope(sourceFilter: "  \n\t ")

        XCTAssertNil(scope.effectiveSourceFilter)
        XCTAssertNil(scope.effectiveTargetFilter)
        XCTAssertFalse(scope.hasFilter)
        XCTAssertNil(scope.filterValidationError)
    }

    func testAFilterIsTrimmedBeforeItIsUsed() {
        let scope = DataTableScope(sourceFilter: "  status = 'active'\n")

        XCTAssertEqual(scope.effectiveSourceFilter, "status = 'active'")
    }

    func testANilTargetFilterReusesTheSourceFilter() {
        let scope = DataTableScope(sourceFilter: " status = 'active' ")

        XCTAssertTrue(scope.usesSameFilterForTarget)
        XCTAssertEqual(scope.effectiveTargetFilter, "status = 'active'")
        XCTAssertTrue(scope.hasFilter)
    }

    /// An empty target filter is a choice to read the whole target, not a request to reuse the
    /// source filter, so the two must stay distinguishable.
    func testAnEmptyTargetFilterReadsTheWholeTarget() {
        let scope = DataTableScope(sourceFilter: "status = 'active'", targetFilter: "")

        XCTAssertFalse(scope.usesSameFilterForTarget)
        XCTAssertEqual(scope.effectiveSourceFilter, "status = 'active'")
        XCTAssertNil(scope.effectiveTargetFilter)
        XCTAssertTrue(scope.hasFilter)
    }

    func testATargetOnlyFilterLeavesTheSourceUnfiltered() {
        let scope = DataTableScope(sourceFilter: "   ", targetFilter: "region = 'eu'")

        XCTAssertNil(scope.effectiveSourceFilter)
        XCTAssertEqual(scope.effectiveTargetFilter, "region = 'eu'")
        XCTAssertTrue(scope.hasFilter)
    }

    func testAnInvalidSourceFilterIsReported() {
        let scope = DataTableScope(sourceFilter: "(status = 'active'")

        XCTAssertNotNil(scope.filterValidationError)
    }

    func testAnInvalidTargetFilterIsReportedEvenWhenTheSourceFilterIsValid() {
        let scope = DataTableScope(sourceFilter: "status = 'active'", targetFilter: "region = 'eu")

        XCTAssertNotNil(scope.filterValidationError)
    }

    func testTwoValidFiltersReportNoError() {
        let scope = DataTableScope(sourceFilter: "status = 'active'", targetFilter: "region = 'eu'")

        XCTAssertNil(scope.filterValidationError)
    }

    // MARK: - Row limit

    func testSetRowLimitClampsZeroAndNegativeValuesToOne() {
        var scope = DataTableScope()

        scope.setRowLimit(0)
        XCTAssertEqual(scope.rowLimit, 1)

        scope.setRowLimit(-25)
        XCTAssertEqual(scope.rowLimit, 1)

        scope.setRowLimit(500)
        XCTAssertEqual(scope.rowLimit, 500)

        scope.setRowLimit(nil)
        XCTAssertNil(scope.rowLimit)
    }

    func testTheInitializerClampsTheRowLimitTheSameWay() {
        XCTAssertEqual(DataTableScope(rowLimit: 0).rowLimit, 1)
        XCTAssertEqual(DataTableScope(rowLimit: -3).rowLimit, 1)
        XCTAssertEqual(DataTableScope(rowLimit: 10).rowLimit, 10)
        XCTAssertNil(DataTableScope().rowLimit)
    }

    // MARK: - Columns

    func testExcludedColumnsMatchWithoutRegardToCase() {
        var scope = DataTableScope(excludedColumns: ["Updated_At"])

        XCTAssertTrue(scope.isExcluded("updated_at"))
        XCTAssertTrue(scope.isExcluded("UPDATED_AT"))

        scope.setExcluded(true, column: "Notes")
        XCTAssertTrue(scope.isExcluded("NOTES"))

        scope.setExcluded(false, column: "notes")
        scope.setExcluded(false, column: "UPDATED_at")
        XCTAssertFalse(scope.isExcluded("Notes"))
        XCTAssertFalse(scope.isExcluded("updated_at"))
        XCTAssertTrue(scope.excludedColumns.isEmpty)
    }

    func testExcludingOneColumnInTwoSpellingsKeepsOneEntry() {
        var scope = DataTableScope()

        scope.setExcluded(true, column: "Email")
        scope.setExcluded(true, column: "EMAIL")

        XCTAssertEqual(scope.excludedColumns, ["email"])
    }

    func testKeyColumnsMatchWithoutRegardToCase() {
        let scope = DataTableScope(keyColumns: ["Tenant_Id", "id"])

        XCTAssertTrue(scope.isKeyColumn("tenant_id"))
        XCTAssertTrue(scope.isKeyColumn("ID"))
        XCTAssertFalse(scope.isKeyColumn("name"))
    }

    func testRestrictExclusionsDropsColumnsTheTableNoLongerHas() {
        var scope = DataTableScope(excludedColumns: ["name", "dropped_column"])

        scope.restrictExclusions(to: ["ID", "Name"])

        XCTAssertEqual(scope.excludedColumns, ["name"])
        XCTAssertTrue(scope.isExcluded("Name"))
        XCTAssertFalse(scope.isExcluded("dropped_column"))
    }

    func testRestrictExclusionsToNoColumnsClearsThemAll() {
        var scope = DataTableScope(excludedColumns: ["name"])

        scope.restrictExclusions(to: [])

        XCTAssertTrue(scope.excludedColumns.isEmpty)
    }

    // MARK: - Coding

    func testDecodingAnEmptyObjectGivesTheDefaults() throws {
        let scope = try JSONDecoder().decode(DataTableScope.self, from: Data("{}".utf8))

        XCTAssertEqual(scope.keyColumns, [])
        XCTAssertTrue(scope.excludedColumns.isEmpty)
        XCTAssertEqual(scope.sourceFilter, "")
        XCTAssertNil(scope.targetFilter)
        XCTAssertNil(scope.rowLimit)
        XCTAssertEqual(scope, DataTableScope())
    }

    func testDecodingLowercasesExclusionsAndClampsTheRowLimit() throws {
        let json = #"{"excludedColumns": ["Updated_At"], "rowLimit": 0}"#

        let scope = try JSONDecoder().decode(DataTableScope.self, from: Data(json.utf8))

        XCTAssertEqual(scope.excludedColumns, ["updated_at"])
        XCTAssertEqual(scope.rowLimit, 1)
    }

    func testEncodingThenDecodingRoundTrips() throws {
        let scope = DataTableScope(
            keyColumns: ["tenant", "id"],
            excludedColumns: ["updated_at", "notes"],
            sourceFilter: "status = 'active'",
            targetFilter: "",
            rowLimit: 250
        )

        let decoded = try JSONDecoder().decode(DataTableScope.self, from: JSONEncoder().encode(scope))

        XCTAssertEqual(decoded, scope)
        XCTAssertEqual(decoded.targetFilter, "", "an empty target filter must not come back as the shared filter")
        XCTAssertFalse(decoded.usesSameFilterForTarget)
    }

    func testASharedFilterStaysSharedAcrossARoundTrip() throws {
        let scope = DataTableScope(keyColumns: ["id"], sourceFilter: "status = 'active'")

        let decoded = try JSONDecoder().decode(DataTableScope.self, from: JSONEncoder().encode(scope))

        XCTAssertNil(decoded.targetFilter)
        XCTAssertTrue(decoded.usesSameFilterForTarget)
        XCTAssertEqual(decoded, scope)
    }
}

final class CompareRowFilterValidationTests: XCTestCase {
    private let semicolonMessage = String(
        localized: "A filter is a single condition and cannot contain a semicolon."
    )
    private let commentMessage = String(localized: "A filter cannot contain a comment.")
    private let unbalancedMessage = String(
        localized: "A quote or parenthesis in this filter is not closed."
    )

    func testAPlainConditionIsAccepted() {
        XCTAssertNil(CompareRowFilter.validationError(for: "status = 'active'"))
        XCTAssertNil(CompareRowFilter.validationError(for: "id > 100 AND region = 'eu'"))
    }

    func testAnEmptyFilterIsAccepted() {
        XCTAssertNil(CompareRowFilter.validationError(for: ""))
        XCTAssertNil(CompareRowFilter.validationError(for: "   \n "))
    }

    /// A filter is one condition, so a semicolon is refused wherever it sits, literal included.
    func testASemicolonInsideALiteralIsStillRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "name = 'a;b'"), semicolonMessage)
    }

    func testAStackedStatementIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "1=1; DELETE FROM t"), semicolonMessage)
    }

    func testALineCommentIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "id = 1 -- x"), commentMessage)
    }

    func testABlockCommentIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "a /* b */"), commentMessage)
    }

    func testAnUnclosedParenthesisIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "(a = 1"), unbalancedMessage)
    }

    func testAStrayClosingParenthesisIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 1)"), unbalancedMessage)
    }

    /// The filter is wrapped in parentheses before it reaches the query, so a filter that closes
    /// the wrapper and opens its own would escape it.
    func testAFilterThatClosesTheWrapperIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 1) OR (1 = 1"), unbalancedMessage)
    }

    func testAnUnclosedQuoteIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 'open"), unbalancedMessage)
    }

    func testAParenthesisInsideALiteralDoesNotCount() {
        XCTAssertNil(CompareRowFilter.validationError(for: "a IN (1, 2) AND (b = 'x)')"))
    }

    func testADoubledQuoteStaysInsideTheLiteral() {
        XCTAssertNil(CompareRowFilter.validationError(for: "name = 'O''Hara'"))
        XCTAssertEqual(CompareRowFilter.validationError(for: "name = 'O''Hara"), unbalancedMessage)
    }

    func testQuotedIdentifiersMayHoldParentheses() {
        XCTAssertNil(CompareRowFilter.validationError(for: "\"odd)name\" = 1"))
        XCTAssertNil(CompareRowFilter.validationError(for: "[odd(name] = 1"))
        XCTAssertNil(CompareRowFilter.validationError(for: "`odd(name` = 1"))
    }

    func testNormalizedTrimsAndTreatsBlankAsNil() {
        XCTAssertEqual(CompareRowFilter.normalized("  a = 1 \n"), "a = 1")
        XCTAssertNil(CompareRowFilter.normalized("   "))
        XCTAssertNil(CompareRowFilter.normalized(nil))
    }

    func testAConditionIsWrappedInParentheses() {
        XCTAssertEqual(CompareRowFilter.condition(for: "a = 1 OR b = 2"), "(a = 1 OR b = 2)")
    }

    /// `#` is MySQL's line comment, and the filter is spliced into a one-line statement, so it
    /// would comment out the ordering and the row limit that follow it.
    func testAHashCommentIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 1 # rest"), commentMessage)
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 1#rest"), commentMessage)
    }

    func testALineCommentWithNoSpaceBeforeItIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "id = 1--x"), commentMessage)
    }

    /// MySQL, MariaDB and ClickHouse read a backslash inside a literal as an escape and PostgreSQL
    /// does not, so a filter only one of them reads as balanced is refused rather than spliced.
    func testAFilterThatOnlyBalancesUnderOneBackslashReadingIsRefused() {
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 'x\\' AND (1=1 OR y='"), unbalancedMessage)
        XCTAssertEqual(CompareRowFilter.validationError(for: "a = 'x\\'"), unbalancedMessage)
    }

    func testABackslashThatBalancesUnderBothReadingsIsAccepted() {
        XCTAssertNil(CompareRowFilter.validationError(for: "path LIKE 'C:\\\\Users%'"))
    }
}

final class SQLRowLimitClauseTests: XCTestCase {

    // MARK: - Style

    func testNoDialectMeansLimit() {
        XCTAssertEqual(SQLRowLimitClause.style(for: nil), .limit)
    }

    func testAnOffsetFetchDialectOutranksTop() {
        let dialect = ScopeDialect.make(paginationStyle: .offsetFetch, autoLimitStyle: .top)

        XCTAssertEqual(SQLRowLimitClause.style(for: dialect), .offsetFetch)
    }

    func testTopIsUsedWhenPaginationIsLimit() {
        let dialect = ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)

        XCTAssertEqual(SQLRowLimitClause.style(for: dialect), .top)
    }

    // MARK: - Statements

    func testNoDialectEmitsALimitClauseLast() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", where: "a = 1", orderBy: "k", limit: 10, dialect: nil
        )

        XCTAssertEqual(sql, "SELECT * FROM t WHERE a = 1 ORDER BY k LIMIT 10")
    }

    func testAnOffsetFetchDialectPutsTheFetchAfterTheOrderBy() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", orderBy: "k", limit: 5, dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )

        XCTAssertEqual(sql, "SELECT * FROM t ORDER BY k OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY")
    }

    /// T-SQL parses OFFSET/FETCH as part of ORDER BY, so a statement with no ordering of its own
    /// still needs the dialect's filler.
    func testAnOffsetFetchDialectWithNoOrderingUsesItsFiller() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", limit: 5, dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )

        XCTAssertEqual(sql, "SELECT * FROM t ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY")
    }

    func testADialectThatDeclaresNoFillerEmitsTheFetchAlone() {
        let dialect = ScopeDialect.make(paginationStyle: .offsetFetch, offsetFetchOrderBy: "")

        let sql = SQLRowLimitClause.select(columns: "*", from: "t", limit: 5, dialect: dialect)

        XCTAssertEqual(sql, "SELECT * FROM t OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY")
    }

    func testATopDialectPutsTheLimitAfterSelect() {
        let dialect = ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)

        let sql = SQLRowLimitClause.select(
            columns: "id", from: "t", where: "a = 1", orderBy: "k", limit: 3, dialect: dialect
        )

        XCTAssertEqual(sql, "SELECT TOP 3 id FROM t WHERE a = 1 ORDER BY k")
    }

    func testNoLimitEmitsNoClauseOnAnyDialect() {
        let dialects: [SQLDialectDescriptor?] = [
            nil,
            ScopeDialect.make(paginationStyle: .offsetFetch),
            ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)
        ]

        for dialect in dialects {
            let sql = SQLRowLimitClause.select(
                columns: "*", from: "t", where: "a = 1", orderBy: "k", dialect: dialect
            )
            XCTAssertEqual(sql, "SELECT * FROM t WHERE a = 1 ORDER BY k")
        }
    }

    func testAnUnlimitedOffsetFetchStatementCarriesNoFiller() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )

        XCTAssertEqual(sql, "SELECT * FROM t")
    }
}

final class KeyOrderedQueryScopeTests: XCTestCase {
    private let driver = ScopeQuotingDriver()

    // MARK: - Reading a side

    func testAFilterIsWrappedInParentheses() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"],
            filter: "status = 'active' OR status = 'trial'", driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(
            sql,
            #"SELECT "id", "name" FROM "users" WHERE (status = 'active' OR status = 'trial')"#
                + #" ORDER BY "id""#
        )
    }

    /// A row limit makes the window the first n keys, and a NULL key has no place in that order, so
    /// the limited read leaves those rows out rather than spending the window on them. The clause
    /// asks for one row more than the limit: the provider never hands that row out, and it is what
    /// separates a side that ends exactly at the limit from one the limit cut short.
    func testARowLimitExcludesNullKeysAndAddsTheLimitClause() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"],
            filter: "status = 'active'", rowLimit: 100, driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(
            sql,
            #"SELECT "id", "name" FROM "users" WHERE (status = 'active') AND "id" IS NOT NULL"#
                + #" ORDER BY "id" LIMIT 101"#
        )
    }

    func testEveryKeyColumnOfACompositeKeyIsCheckedForNull() {
        let sql = KeyOrderedQuery.build(
            table: "orders", schema: nil, columns: ["tenant", "id", "total"], keyColumns: ["tenant", "id"],
            rowLimit: 50, driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(
            sql,
            #"SELECT "tenant", "id", "total" FROM "orders" WHERE "tenant" IS NOT NULL AND "id" IS NOT NULL"#
                + #" ORDER BY "tenant", "id" LIMIT 51"#
        )
    }

    func testWithoutARowLimitNullKeysAreNotFilteredOut() {
        let sql = KeyOrderedQuery.build(
            table: "orders", schema: nil, columns: ["id"], keyColumns: ["id"],
            filter: "total > 10", driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(sql, #"SELECT "id" FROM "orders" WHERE (total > 10) ORDER BY "id""#)
        XCTAssertFalse(sql.contains("IS NOT NULL"))
    }

    func testTheRowLimitFollowsTheDialect() {
        let offsetFetch = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id"], keyColumns: ["id"], rowLimit: 10,
            driver: driver, databaseType: .mssql, dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )
        let top = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id"], keyColumns: ["id"], rowLimit: 10,
            driver: driver, databaseType: .mssql,
            dialect: ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)
        )

        XCTAssertTrue(offsetFetch.hasSuffix(#"ORDER BY "id" OFFSET 0 ROWS FETCH NEXT 11 ROWS ONLY"#), offsetFetch)
        XCTAssertTrue(top.hasPrefix(#"SELECT TOP 11 "id" FROM "#), top)
        XCTAssertTrue(top.hasSuffix(#"ORDER BY "id""#), top)
    }

    // MARK: - Looking rows up by key

    func testALookupOnOneKeyColumnUsesIn() {
        let sql = KeyOrderedQuery.lookup(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"],
            keyTypes: [.integer(rawType: "INT")], keys: [[.text("1")], [.text("2")]],
            driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(sql, #"SELECT "id", "name" FROM "users" WHERE "id" IN (1, 2) ORDER BY "id""#)
    }

    /// A VARCHAR key holding `007` has to stay quoted, or MySQL compares it as 7 and the lookup
    /// answers with rows that are not the ones asked for.
    func testALookupQuotesANumericLookingTextKey() {
        let sql = KeyOrderedQuery.lookup(
            table: "items", schema: nil, columns: ["code"], keyColumns: ["code"],
            keyTypes: [.text(rawType: "VARCHAR(10)")], keys: [[.text("007")], [.text("O'Brien")]],
            driver: driver, databaseType: .mysql
        )

        XCTAssertEqual(sql, #"SELECT "code" FROM "items" WHERE "code" IN ('007', 'O''Brien') ORDER BY "code""#)
    }

    func testALookupOnACompositeKeyOrsParenthesisedConjunctions() {
        let sql = KeyOrderedQuery.lookup(
            table: "orders", schema: nil, columns: ["tenant", "id"], keyColumns: ["tenant", "id"],
            keyTypes: [.text(rawType: "TEXT"), .integer(rawType: "BIGINT")],
            keys: [[.text("acme"), .text("1")], [.text("007"), .text("2")]],
            driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(
            sql,
            #"SELECT "tenant", "id" FROM "orders" WHERE ("tenant" = 'acme' AND "id" = 1)"#
                + #" OR ("tenant" = '007' AND "id" = 2) ORDER BY "tenant", "id""#
        )
    }

    func testALookupQualifiesTheSchema() {
        let sql = KeyOrderedQuery.lookup(
            table: "orders", schema: "app", columns: ["id"], keyColumns: ["id"],
            keyTypes: [.integer(rawType: "INT")], keys: [[.text("1")]],
            driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(sql, #"SELECT "id" FROM "app"."orders" WHERE "id" IN (1) ORDER BY "id""#)
    }

    func testALookupOnSQLServerPrefixesATextKey() {
        let sql = KeyOrderedQuery.lookup(
            table: "customers", schema: nil, columns: ["name"], keyColumns: ["name"],
            keyTypes: [.text(rawType: "NVARCHAR(20)")], keys: [[.text("日本語")]],
            driver: driver, databaseType: .mssql
        )

        XCTAssertTrue(sql.contains(#""name" IN (N'日本語')"#), sql)
    }

    func testALookupWithNoKeyTypesQuotesTheKey() {
        let sql = KeyOrderedQuery.lookup(
            table: "items", schema: nil, columns: ["code"], keyColumns: ["code"],
            keyTypes: [], keys: [[.text("7")]], driver: driver, databaseType: .postgresql
        )

        XCTAssertEqual(sql, #"SELECT "code" FROM "items" WHERE "code" IN ('7') ORDER BY "code""#)
    }
}

final class CompareSQLLiteralTextTests: XCTestCase {
    private let driver = ScopeQuotingDriver()

    func testNumericLookingTextIsQuotedForATextColumn() {
        let literal = CompareSQLLiteral.textLiteral(
            "007", columnType: .text(rawType: "VARCHAR(10)"), databaseType: .mysql, driver: driver
        )

        XCTAssertEqual(literal, "'007'")
    }

    /// With no type to consult the safe answer is the quoted one: a quoted number still compares
    /// against a numeric column, while an unquoted string does not compare against a text one.
    func testNumericLookingTextIsQuotedWhenTheColumnTypeIsUnknown() {
        XCTAssertEqual(
            CompareSQLLiteral.textLiteral("42", columnType: nil, databaseType: .postgresql, driver: driver),
            "'42'"
        )
    }

    func testAnIntegerColumnKeepsANumberBare() {
        let positive = CompareSQLLiteral.textLiteral(
            "42", columnType: .integer(rawType: "INT"), databaseType: .mysql, driver: driver
        )
        let negative = CompareSQLLiteral.textLiteral(
            "-17", columnType: .integer(rawType: "INT"), databaseType: .mysql, driver: driver
        )

        XCTAssertEqual(positive, "42")
        XCTAssertEqual(negative, "-17")
    }

    func testADecimalColumnKeepsANumberBare() {
        let literal = CompareSQLLiteral.textLiteral(
            "3.50", columnType: .decimal(rawType: "NUMERIC(10,2)"), databaseType: .postgresql, driver: driver
        )

        XCTAssertEqual(literal, "3.50")
    }

    func testTextThatIsNotANumberIsQuotedEvenForANumericColumn() {
        let literal = CompareSQLLiteral.textLiteral(
            "abc", columnType: .integer(rawType: "INT"), databaseType: .postgresql, driver: driver
        )

        XCTAssertEqual(literal, "'abc'")
    }

    func testSQLServerKeepsItsPrefixOnQuotedText() {
        XCTAssertEqual(
            CompareSQLLiteral.textLiteral(
                "007", columnType: .text(rawType: "NVARCHAR(10)"), databaseType: .mssql, driver: driver
            ),
            "N'007'"
        )
        XCTAssertEqual(
            CompareSQLLiteral.textLiteral("O'Hara", columnType: nil, databaseType: .mssql, driver: driver),
            "N'O''Hara'"
        )
    }

    func testSQLServerLeavesABareNumberUnprefixed() {
        let literal = CompareSQLLiteral.textLiteral(
            "42", columnType: .integer(rawType: "INT"), databaseType: .mssql, driver: driver
        )

        XCTAssertEqual(literal, "42")
    }

    func testLiteralRoutesNullAndTextThroughTheSameRules() {
        XCTAssertEqual(
            CompareSQLLiteral.literal(
                for: .null, columnType: .text(rawType: "TEXT"), databaseType: .mssql, driver: driver
            ),
            "NULL"
        )
        XCTAssertEqual(
            CompareSQLLiteral.literal(
                for: .text("007"), columnType: .text(rawType: "CHAR(3)"), databaseType: .mysql, driver: driver
            ),
            "'007'"
        )
    }
}

final class DataCompareOptionsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> DataCompareOptions {
        try JSONDecoder().decode(DataCompareOptions.self, from: Data(json.utf8))
    }

    func testAnObjectWithOneKeyFillsTheRestWithDefaults() throws {
        let options = try decode(#"{"insertMissingRows": false}"#)

        XCTAssertFalse(options.insertMissingRows)
        XCTAssertTrue(options.updateDifferingRows)
        XCTAssertFalse(options.deleteExtraRows)
        XCTAssertEqual(options.floatTolerance, 0)
        XCTAssertEqual(options.timestampFractionalDigits, 6)
        XCTAssertEqual(options.maxRetainedEntries, 5_000)
        XCTAssertEqual(options.maxRetainedIdenticalEntries, 1_000)
    }

    func testAnEmptyObjectDecodesToTheDefaults() throws {
        XCTAssertEqual(try decode("{}"), .default)
    }

    /// Key columns and excluded columns moved to each table's own scope. A profile written before
    /// that still carries them, and decoding must step over them rather than fail.
    func testRetiredKeysAreIgnored() throws {
        let json = #"{"keyColumns": ["id"], "excludedFromComparison": ["updated_at"], "deleteExtraRows": true}"#

        let options = try decode(json)

        var expected = DataCompareOptions()
        expected.deleteExtraRows = true
        XCTAssertEqual(options, expected)
    }

    func testEncodingWritesTheCurrentKeysOnly() throws {
        let data = try JSONEncoder().encode(DataCompareOptions.default)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            [
                "insertMissingRows", "updateDifferingRows", "deleteExtraRows", "floatTolerance",
                "timestampFractionalDigits", "maxRetainedEntries", "maxRetainedIdenticalEntries"
            ]
        )
    }

    func testEncodingThenDecodingRoundTrips() throws {
        var options = DataCompareOptions()
        options.insertMissingRows = false
        options.updateDifferingRows = false
        options.deleteExtraRows = true
        options.floatTolerance = 0.001
        options.timestampFractionalDigits = 3
        options.maxRetainedEntries = 10
        options.maxRetainedIdenticalEntries = 2

        let decoded = try JSONDecoder().decode(DataCompareOptions.self, from: JSONEncoder().encode(options))

        XCTAssertEqual(decoded, options)
    }

    func testWritesRowsFollowsTheThreeToggles() {
        var options = DataCompareOptions()
        options.insertMissingRows = true
        options.updateDifferingRows = false
        options.deleteExtraRows = true

        XCTAssertTrue(options.writesRows(of: .insert))
        XCTAssertFalse(options.writesRows(of: .update))
        XCTAssertTrue(options.writesRows(of: .delete))
        XCTAssertFalse(options.writesRows(of: .identical))
        XCTAssertFalse(options.writesRows(of: .conflict))
    }
}

final class CompareSyncProfileScopeCodingTests: XCTestCase {
    private let profileId = UUID()
    private let sourceConnection = UUID()
    private let targetConnection = UUID()

    private let legacyDataOptions = #"""
    {
        "keyColumns": ["id"],
        "excludedFromComparison": ["updated_at"],
        "insertMissingRows": true,
        "updateDifferingRows": false,
        "deleteExtraRows": true,
        "floatTolerance": 0,
        "timestampFractionalDigits": 6,
        "maxRetainedEntries": 5000
    }
    """#

    private func legacyProfileJSON(dataOptions: String?) -> Data {
        let dataOptionsField = dataOptions.map { #", "dataOptions": \#($0)"# } ?? ""
        let json = #"""
        {
            "id": "\#(profileId.uuidString)",
            "name": "Nightly",
            "source": {"connectionId": "\#(sourceConnection.uuidString)", "database": "prod", "schema": "public"},
            "target": {"connectionId": "\#(targetConnection.uuidString)", "database": "staging"},
            "mode": "data",
            "includedKinds": ["table"],
            "selectedObjects": ["orders"]\#(dataOptionsField)
        }
        """#
        return Data(json.utf8)
    }

    private func profile(tableScopes: [String: DataTableScope], legacy: Set<String> = []) -> CompareSyncProfile {
        CompareSyncProfile(
            id: profileId,
            name: "Nightly",
            source: DatabaseScope(connectionId: sourceConnection, database: "prod", schema: "public"),
            target: DatabaseScope(connectionId: targetConnection, database: "staging", schema: "public"),
            mode: .data,
            includedKinds: [.table],
            structureOptions: .default,
            dataOptions: .default,
            selectedObjects: ["public\u{1F}orders"],
            tableScopes: tableScopes,
            legacyExcludedColumns: legacy
        )
    }

    /// A profile saved before exclusions became per table keeps leaving out the columns it left
    /// out, so the first comparison after an update does not report every row as different.
    func testAProfileSavedBeforeTableScopesKeepsItsExcludedColumns() throws {
        let decoded = try JSONDecoder().decode(
            CompareSyncProfile.self, from: legacyProfileJSON(dataOptions: legacyDataOptions)
        )

        XCTAssertEqual(decoded.id, profileId)
        XCTAssertEqual(decoded.name, "Nightly")
        XCTAssertEqual(decoded.mode, .data)
        XCTAssertEqual(decoded.source.database, "prod")
        XCTAssertEqual(decoded.source.schema, "public")
        XCTAssertNil(decoded.target.schema)
        XCTAssertEqual(decoded.tableScopes, [:])
        XCTAssertEqual(decoded.legacyExcludedColumns, ["updated_at"])
        XCTAssertFalse(decoded.dataOptions.updateDifferingRows)
        XCTAssertTrue(decoded.dataOptions.deleteExtraRows)
        XCTAssertEqual(decoded.structureOptions, .default)
        XCTAssertEqual(decoded.selectedObjects, ["orders"])
    }

    func testAProfileWithNoDataOptionsCarriesNoLegacyExclusions() throws {
        let decoded = try JSONDecoder().decode(
            CompareSyncProfile.self, from: legacyProfileJSON(dataOptions: nil)
        )

        XCTAssertEqual(decoded.dataOptions, .default)
        XCTAssertTrue(decoded.legacyExcludedColumns.isEmpty)
        XCTAssertEqual(decoded.tableScopes, [:])
    }

    func testTableScopesRoundTrip() throws {
        let key = "public\u{1F}orders"
        let original = profile(tableScopes: [
            key: DataTableScope(
                keyColumns: ["tenant", "id"],
                excludedColumns: ["updated_at"],
                sourceFilter: "status = 'open'",
                targetFilter: "",
                rowLimit: 500
            ),
            "public\u{1F}customers": DataTableScope(keyColumns: ["id"])
        ])

        let decoded = try JSONDecoder().decode(CompareSyncProfile.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.tableScopes, original.tableScopes)
        XCTAssertEqual(decoded.tableScopes[key]?.rowLimit, 500)
        XCTAssertEqual(decoded.tableScopes[key]?.targetFilter, "")
        XCTAssertEqual(decoded, original)
    }

    /// Saving or deleting any one comparison rewrites the whole stored array, so a comparison the
    /// user has not opened yet keeps the columns it was told to leave out. They move onto its table
    /// scopes the first time its tables load, and the session stops writing them from then on.
    func testLegacyExcludedColumnsSurviveARewriteUntilTheTablesLoad() throws {
        let data = try JSONEncoder().encode(profile(tableScopes: [:], legacy: ["updated_at"]))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["legacyExcludedColumns"] as? [String], ["updated_at"])
        let dataOptions = try XCTUnwrap(object["dataOptions"] as? [String: Any])
        XCTAssertNil(dataOptions["excludedFromComparison"], "the option they used to live in is gone")

        let decoded = try JSONDecoder().decode(CompareSyncProfile.self, from: data)
        XCTAssertEqual(decoded.legacyExcludedColumns, ["updated_at"])
    }
}
