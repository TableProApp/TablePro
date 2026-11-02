//
//  CompareDataScopeTests.swift
//  TableProTests
//
//  What one table contributes to a data comparison: its key, its excluded columns, its filters and
//  its row limit, the SQL those turn into, and how a saved setup reads back.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class ScopeQuotingDriver: PluginDriverStub, @unchecked Sendable {
    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

private final class BackslashLiteralDriver: PluginDriverStub, @unchecked Sendable {
    var requiresBackslashEscapingInLiterals: Bool { true }
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

struct DataTableScopeTests {

    // MARK: - Filters

    @Test
    func aWhitespaceOnlyFilterIsNoFilter() {
        let scope = DataTableScope(sourceFilter: "  \n\t ")

        #expect(scope.effectiveSourceFilter == nil)
        #expect(scope.effectiveTargetFilter == nil)
        #expect(!scope.hasFilter)
        #expect(scope.filterValidationError == nil)
    }

    @Test
    func aFilterIsTrimmedBeforeItIsUsed() {
        let scope = DataTableScope(sourceFilter: "  status = 'active'\n")

        #expect(scope.effectiveSourceFilter == "status = 'active'")
    }

    @Test
    func aNilTargetFilterReusesTheSourceFilter() {
        let scope = DataTableScope(sourceFilter: " status = 'active' ")

        #expect(scope.usesSameFilterForTarget)
        #expect(scope.effectiveTargetFilter == "status = 'active'")
        #expect(scope.hasFilter)
    }

    /// An empty target filter is a choice to read the whole target, not a request to reuse the
    /// source filter, so the two must stay distinguishable.
    @Test
    func anEmptyTargetFilterReadsTheWholeTarget() {
        let scope = DataTableScope(sourceFilter: "status = 'active'", targetFilter: "")

        #expect(!scope.usesSameFilterForTarget)
        #expect(scope.effectiveSourceFilter == "status = 'active'")
        #expect(scope.effectiveTargetFilter == nil)
        #expect(scope.hasFilter)
    }

    @Test
    func aTargetOnlyFilterLeavesTheSourceUnfiltered() {
        let scope = DataTableScope(sourceFilter: "   ", targetFilter: "region = 'eu'")

        #expect(scope.effectiveSourceFilter == nil)
        #expect(scope.effectiveTargetFilter == "region = 'eu'")
        #expect(scope.hasFilter)
    }

    @Test
    func anInvalidSourceFilterIsReported() {
        let scope = DataTableScope(sourceFilter: "(status = 'active'")

        #expect(scope.filterValidationError != nil)
    }

    @Test
    func anInvalidTargetFilterIsReportedEvenWhenTheSourceFilterIsValid() {
        let scope = DataTableScope(sourceFilter: "status = 'active'", targetFilter: "region = 'eu")

        #expect(scope.filterValidationError != nil)
    }

    @Test
    func twoValidFiltersReportNoError() {
        let scope = DataTableScope(sourceFilter: "status = 'active'", targetFilter: "region = 'eu'")

        #expect(scope.filterValidationError == nil)
    }

    // MARK: - Row limit

    @Test
    func setRowLimitClampsZeroAndNegativeValuesToOne() {
        var scope = DataTableScope()

        scope.setRowLimit(0)
        #expect(scope.rowLimit == 1)

        scope.setRowLimit(-25)
        #expect(scope.rowLimit == 1)

        scope.setRowLimit(500)
        #expect(scope.rowLimit == 500)

        scope.setRowLimit(nil)
        #expect(scope.rowLimit == nil)
    }

    @Test
    func theInitializerClampsTheRowLimitTheSameWay() {
        #expect(DataTableScope(rowLimit: 0).rowLimit == 1)
        #expect(DataTableScope(rowLimit: -3).rowLimit == 1)
        #expect(DataTableScope(rowLimit: 10).rowLimit == 10)
        #expect(DataTableScope().rowLimit == nil)
    }

    // MARK: - Columns

    @Test
    func excludedColumnsMatchWithoutRegardToCase() {
        var scope = DataTableScope(excludedColumns: ["Updated_At"])

        #expect(scope.isExcluded("updated_at"))
        #expect(scope.isExcluded("UPDATED_AT"))

        scope.setExcluded(true, column: "Notes")
        #expect(scope.isExcluded("NOTES"))

        scope.setExcluded(false, column: "notes")
        scope.setExcluded(false, column: "UPDATED_at")
        #expect(!scope.isExcluded("Notes"))
        #expect(!scope.isExcluded("updated_at"))
        #expect(scope.excludedColumns.isEmpty)
    }

    @Test
    func excludingOneColumnInTwoSpellingsKeepsOneEntry() {
        var scope = DataTableScope()

        scope.setExcluded(true, column: "Email")
        scope.setExcluded(true, column: "EMAIL")

        #expect(scope.excludedColumns == ["email"])
    }

    @Test
    func keyColumnsMatchWithoutRegardToCase() {
        let scope = DataTableScope(keyColumns: ["Tenant_Id", "id"])

        #expect(scope.isKeyColumn("tenant_id"))
        #expect(scope.isKeyColumn("ID"))
        #expect(!scope.isKeyColumn("name"))
    }

    @Test
    func restrictExclusionsDropsColumnsTheTableNoLongerHas() {
        var scope = DataTableScope(excludedColumns: ["name", "dropped_column"])

        scope.restrictExclusions(to: ["ID", "Name"])

        #expect(scope.excludedColumns == ["name"])
        #expect(scope.isExcluded("Name"))
        #expect(!scope.isExcluded("dropped_column"))
    }

    @Test
    func restrictExclusionsToNoColumnsClearsThemAll() {
        var scope = DataTableScope(excludedColumns: ["name"])

        scope.restrictExclusions(to: [])

        #expect(scope.excludedColumns.isEmpty)
    }

    // MARK: - Coding

    @Test
    func decodingAnEmptyObjectGivesTheDefaults() throws {
        let scope = try JSONDecoder().decode(DataTableScope.self, from: Data("{}".utf8))

        #expect(scope.keyColumns == [])
        #expect(scope.excludedColumns.isEmpty)
        #expect(scope.sourceFilter == "")
        #expect(scope.targetFilter == nil)
        #expect(scope.rowLimit == nil)
        #expect(scope == DataTableScope())
    }

    @Test
    func decodingLowercasesExclusionsAndClampsTheRowLimit() throws {
        let json = #"{"excludedColumns": ["Updated_At"], "rowLimit": 0}"#

        let scope = try JSONDecoder().decode(DataTableScope.self, from: Data(json.utf8))

        #expect(scope.excludedColumns == ["updated_at"])
        #expect(scope.rowLimit == 1)
    }

    @Test
    func encodingThenDecodingRoundTrips() throws {
        let scope = DataTableScope(
            keyColumns: ["tenant", "id"],
            excludedColumns: ["updated_at", "notes"],
            sourceFilter: "status = 'active'",
            targetFilter: "",
            rowLimit: 250
        )

        let decoded = try JSONDecoder().decode(DataTableScope.self, from: JSONEncoder().encode(scope))

        #expect(decoded == scope)
        #expect(decoded.targetFilter == "", "an empty target filter must not come back as the shared filter")
        #expect(!decoded.usesSameFilterForTarget)
    }

    @Test
    func aSharedFilterStaysSharedAcrossARoundTrip() throws {
        let scope = DataTableScope(keyColumns: ["id"], sourceFilter: "status = 'active'")

        let decoded = try JSONDecoder().decode(DataTableScope.self, from: JSONEncoder().encode(scope))

        #expect(decoded.targetFilter == nil)
        #expect(decoded.usesSameFilterForTarget)
        #expect(decoded == scope)
    }
}

struct CompareRowFilterValidationTests {
    private let semicolonMessage = String(
        localized: "A filter is a single condition and cannot contain a semicolon."
    )
    private let commentMessage = String(localized: "A filter cannot contain a comment.")
    private let unbalancedMessage = String(
        localized: "A quote or parenthesis in this filter is not closed."
    )

    @Test
    func aPlainConditionIsAccepted() {
        #expect(CompareRowFilter.validationError(for: "status = 'active'") == nil)
        #expect(CompareRowFilter.validationError(for: "id > 100 AND region = 'eu'") == nil)
    }

    @Test
    func anEmptyFilterIsAccepted() {
        #expect(CompareRowFilter.validationError(for: "") == nil)
        #expect(CompareRowFilter.validationError(for: "   \n ") == nil)
    }

    /// A filter is one condition, so a semicolon is refused wherever it sits, literal included.
    @Test
    func aSemicolonInsideALiteralIsStillRefused() {
        #expect(CompareRowFilter.validationError(for: "name = 'a;b'") == semicolonMessage)
    }

    @Test
    func aStackedStatementIsRefused() {
        #expect(CompareRowFilter.validationError(for: "1=1; DELETE FROM t") == semicolonMessage)
    }

    @Test
    func aLineCommentIsRefused() {
        #expect(CompareRowFilter.validationError(for: "id = 1 -- x") == commentMessage)
    }

    @Test
    func aBlockCommentIsRefused() {
        #expect(CompareRowFilter.validationError(for: "a /* b */") == commentMessage)
    }

    @Test
    func anUnclosedParenthesisIsRefused() {
        #expect(CompareRowFilter.validationError(for: "(a = 1") == unbalancedMessage)
    }

    @Test
    func aStrayClosingParenthesisIsRefused() {
        #expect(CompareRowFilter.validationError(for: "a = 1)") == unbalancedMessage)
    }

    /// The filter is wrapped in parentheses before it reaches the query, so a filter that closes
    /// the wrapper and opens its own would escape it.
    @Test
    func aFilterThatClosesTheWrapperIsRefused() {
        #expect(CompareRowFilter.validationError(for: "a = 1) OR (1 = 1") == unbalancedMessage)
    }

    @Test
    func anUnclosedQuoteIsRefused() {
        #expect(CompareRowFilter.validationError(for: "a = 'open") == unbalancedMessage)
    }

    @Test
    func aParenthesisInsideALiteralDoesNotCount() {
        #expect(CompareRowFilter.validationError(for: "a IN (1, 2) AND (b = 'x)')") == nil)
    }

    @Test
    func aDoubledQuoteStaysInsideTheLiteral() {
        #expect(CompareRowFilter.validationError(for: "name = 'O''Hara'") == nil)
        #expect(CompareRowFilter.validationError(for: "name = 'O''Hara") == unbalancedMessage)
    }

    @Test
    func quotedIdentifiersMayHoldParentheses() {
        #expect(CompareRowFilter.validationError(for: "\"odd)name\" = 1") == nil)
        #expect(CompareRowFilter.validationError(for: "[odd(name] = 1") == nil)
        #expect(CompareRowFilter.validationError(for: "`odd(name` = 1") == nil)
    }

    @Test
    func normalizedTrimsAndTreatsBlankAsNil() {
        #expect(CompareRowFilter.normalized("  a = 1 \n") == "a = 1")
        #expect(CompareRowFilter.normalized("   ") == nil)
        #expect(CompareRowFilter.normalized(nil) == nil)
    }

    @Test
    func aConditionIsWrappedInParentheses() {
        #expect(CompareRowFilter.condition(for: "a = 1 OR b = 2") == "(a = 1 OR b = 2)")
    }

    /// `#` is MySQL's line comment, and the filter is spliced into a one-line statement, so it
    /// would comment out the ordering and the row limit that follow it.
    @Test
    func aHashCommentIsRefused() {
        #expect(CompareRowFilter.validationError(for: "a = 1 # rest") == commentMessage)
        #expect(CompareRowFilter.validationError(for: "a = 1#rest") == commentMessage)
    }

    @Test
    func aLineCommentWithNoSpaceBeforeItIsRefused() {
        #expect(CompareRowFilter.validationError(for: "id = 1--x") == commentMessage)
    }

    /// MySQL, MariaDB and ClickHouse read a backslash inside a literal as an escape and PostgreSQL
    /// does not, so a filter only one of them reads as balanced is refused rather than spliced.
    @Test
    func aFilterThatOnlyBalancesUnderOneBackslashReadingIsRefused() {
        #expect(CompareRowFilter.validationError(for: "a = 'x\\' AND (1=1 OR y='") == unbalancedMessage)
        #expect(CompareRowFilter.validationError(for: "a = 'x\\'") == unbalancedMessage)
    }

    @Test
    func aBackslashThatBalancesUnderBothReadingsIsAccepted() {
        #expect(CompareRowFilter.validationError(for: "path LIKE 'C:\\\\Users%'") == nil)
    }
}

struct SQLRowLimitClauseTests {

    // MARK: - Style

    @Test
    func noDialectMeansLimit() {
        #expect(SQLRowLimitClause.style(for: nil) == .limit)
    }

    @Test
    func anOffsetFetchDialectOutranksTop() {
        let dialect = ScopeDialect.make(paginationStyle: .offsetFetch, autoLimitStyle: .top)

        #expect(SQLRowLimitClause.style(for: dialect) == .offsetFetch)
    }

    @Test
    func topIsUsedWhenPaginationIsLimit() {
        let dialect = ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)

        #expect(SQLRowLimitClause.style(for: dialect) == .top)
    }

    // MARK: - Statements

    @Test
    func noDialectEmitsALimitClauseLast() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", where: "a = 1", orderBy: "k", limit: 10, dialect: nil
        )

        #expect(sql == "SELECT * FROM t WHERE a = 1 ORDER BY k LIMIT 10")
    }

    @Test
    func anOffsetFetchDialectPutsTheFetchAfterTheOrderBy() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", orderBy: "k", limit: 5, dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )

        #expect(sql == "SELECT * FROM t ORDER BY k OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY")
    }

    /// T-SQL parses OFFSET/FETCH as part of ORDER BY, so a statement with no ordering of its own
    /// still needs the dialect's filler.
    @Test
    func anOffsetFetchDialectWithNoOrderingUsesItsFiller() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", limit: 5, dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )

        #expect(sql == "SELECT * FROM t ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY")
    }

    @Test
    func aDialectThatDeclaresNoFillerEmitsTheFetchAlone() {
        let dialect = ScopeDialect.make(paginationStyle: .offsetFetch, offsetFetchOrderBy: "")

        let sql = SQLRowLimitClause.select(columns: "*", from: "t", limit: 5, dialect: dialect)

        #expect(sql == "SELECT * FROM t OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY")
    }

    @Test
    func aTopDialectPutsTheLimitAfterSelect() {
        let dialect = ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)

        let sql = SQLRowLimitClause.select(
            columns: "id", from: "t", where: "a = 1", orderBy: "k", limit: 3, dialect: dialect
        )

        #expect(sql == "SELECT TOP 3 id FROM t WHERE a = 1 ORDER BY k")
    }

    @Test
    func noLimitEmitsNoClauseOnAnyDialect() {
        let dialects: [SQLDialectDescriptor?] = [
            nil,
            ScopeDialect.make(paginationStyle: .offsetFetch),
            ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)
        ]

        for dialect in dialects {
            let sql = SQLRowLimitClause.select(
                columns: "*", from: "t", where: "a = 1", orderBy: "k", dialect: dialect
            )
            #expect(sql == "SELECT * FROM t WHERE a = 1 ORDER BY k")
        }
    }

    @Test
    func anUnlimitedOffsetFetchStatementCarriesNoFiller() {
        let sql = SQLRowLimitClause.select(
            columns: "*", from: "t", dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )

        #expect(sql == "SELECT * FROM t")
    }
}

struct KeyOrderedQueryScopeTests {
    private let driver = ScopeQuotingDriver()

    // MARK: - Reading a side

    @Test
    func aFilterIsWrappedInParentheses() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"],
            filter: "status = 'active' OR status = 'trial'", driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "id", "name" FROM "users" WHERE (status = 'active' OR status = 'trial')"#
                + #" ORDER BY "id""#)
    }

    /// A row limit makes the window the first n keys, and a NULL key has no place in that order, so
    /// the limited read leaves those rows out rather than spending the window on them. The clause
    /// asks for one row more than the limit: the provider never hands that row out, and it is what
    /// separates a side that ends exactly at the limit from one the limit cut short.
    @Test
    func aRowLimitExcludesNullKeysAndAddsTheLimitClause() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"],
            filter: "status = 'active'", rowLimit: 100, driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "id", "name" FROM "users" WHERE (status = 'active') AND "id" IS NOT NULL"#
                + #" ORDER BY "id" LIMIT 101"#)
    }

    @Test
    func everyKeyColumnOfACompositeKeyIsCheckedForNull() {
        let sql = KeyOrderedQuery.build(
            table: "orders", schema: nil, columns: ["tenant", "id", "total"], keyColumns: ["tenant", "id"],
            rowLimit: 50, driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "tenant", "id", "total" FROM "orders" WHERE "tenant" IS NOT NULL AND "id" IS NOT NULL"#
                + #" ORDER BY "tenant", "id" LIMIT 51"#)
    }

    @Test
    func withoutARowLimitNullKeysAreNotFilteredOut() {
        let sql = KeyOrderedQuery.build(
            table: "orders", schema: nil, columns: ["id"], keyColumns: ["id"],
            filter: "total > 10", driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "id" FROM "orders" WHERE (total > 10) ORDER BY "id""#)
        #expect(!sql.contains("IS NOT NULL"))
    }

    @Test
    func theRowLimitFollowsTheDialect() {
        let offsetFetch = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id"], keyColumns: ["id"], rowLimit: 10,
            driver: driver, databaseType: .mssql, dialect: ScopeDialect.make(paginationStyle: .offsetFetch)
        )
        let top = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id"], keyColumns: ["id"], rowLimit: 10,
            driver: driver, databaseType: .mssql,
            dialect: ScopeDialect.make(paginationStyle: .limit, autoLimitStyle: .top)
        )

        #expect(offsetFetch.hasSuffix(#"ORDER BY "id" OFFSET 0 ROWS FETCH NEXT 11 ROWS ONLY"#), Comment(rawValue: offsetFetch))
        #expect(top.hasPrefix(#"SELECT TOP 11 "id" FROM "#), Comment(rawValue: top))
        #expect(top.hasSuffix(#"ORDER BY "id""#), Comment(rawValue: top))
    }

    // MARK: - Looking rows up by key

    @Test
    func aLookupOnOneKeyColumnUsesIn() {
        let sql = KeyOrderedQuery.lookup(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"],
            keyTypes: [.integer(rawType: "INT")], keys: [[.text("1")], [.text("2")]],
            driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "id", "name" FROM "users" WHERE "id" IN (1, 2) ORDER BY "id""#)
    }

    /// A VARCHAR key holding `007` has to stay quoted, or MySQL compares it as 7 and the lookup
    /// answers with rows that are not the ones asked for.
    @Test
    func aLookupQuotesANumericLookingTextKey() {
        let sql = KeyOrderedQuery.lookup(
            table: "items", schema: nil, columns: ["code"], keyColumns: ["code"],
            keyTypes: [.text(rawType: "VARCHAR(10)")], keys: [[.text("007")], [.text("O'Brien")]],
            driver: driver, databaseType: .mysql
        )

        #expect(sql == #"SELECT "code" FROM "items" WHERE "code" IN ('007', 'O''Brien') ORDER BY "code""#)
    }

    @Test
    func aLookupOnACompositeKeyOrsParenthesisedConjunctions() {
        let sql = KeyOrderedQuery.lookup(
            table: "orders", schema: nil, columns: ["tenant", "id"], keyColumns: ["tenant", "id"],
            keyTypes: [.text(rawType: "TEXT"), .integer(rawType: "BIGINT")],
            keys: [[.text("acme"), .text("1")], [.text("007"), .text("2")]],
            driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "tenant", "id" FROM "orders" WHERE ("tenant" = 'acme' AND "id" = 1)"#
                + #" OR ("tenant" = '007' AND "id" = 2) ORDER BY "tenant", "id""#)
    }

    @Test
    func aLookupQualifiesTheSchema() {
        let sql = KeyOrderedQuery.lookup(
            table: "orders", schema: "app", columns: ["id"], keyColumns: ["id"],
            keyTypes: [.integer(rawType: "INT")], keys: [[.text("1")]],
            driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "id" FROM "app"."orders" WHERE "id" IN (1) ORDER BY "id""#)
    }

    @Test
    func aLookupOnSQLServerPrefixesATextKey() {
        let sql = KeyOrderedQuery.lookup(
            table: "customers", schema: nil, columns: ["name"], keyColumns: ["name"],
            keyTypes: [.text(rawType: "NVARCHAR(20)")], keys: [[.text("日本語")]],
            driver: driver, databaseType: .mssql
        )

        #expect(sql.contains(#""name" IN (N'日本語')"#), Comment(rawValue: sql))
    }

    @Test
    func aLookupWithNoKeyTypesQuotesTheKey() {
        let sql = KeyOrderedQuery.lookup(
            table: "items", schema: nil, columns: ["code"], keyColumns: ["code"],
            keyTypes: [], keys: [[.text("7")]], driver: driver, databaseType: .postgresql
        )

        #expect(sql == #"SELECT "code" FROM "items" WHERE "code" IN ('7') ORDER BY "code""#)
    }
}

struct CompareSQLLiteralTextTests {
    private let driver = ScopeQuotingDriver()

    @Test
    func aValueLedByACombiningMarkKeepsTheDriversBackslashEscape() {
        let literal = CompareSQLLiteral.textLiteral(
            "\u{301}\\' OR 1=1 -- ", columnType: .text(rawType: "TEXT"), databaseType: .mysql,
            driver: BackslashLiteralDriver()
        )

        #expect(Array(literal.unicodeScalars) == Array("'\u{301}\\\\'' OR 1=1 -- '".unicodeScalars))
    }

    @Test
    func numericLookingTextIsQuotedForATextColumn() {
        let literal = CompareSQLLiteral.textLiteral(
            "007", columnType: .text(rawType: "VARCHAR(10)"), databaseType: .mysql, driver: driver
        )

        #expect(literal == "'007'")
    }

    /// With no type to consult the safe answer is the quoted one: a quoted number still compares
    /// against a numeric column, while an unquoted string does not compare against a text one.
    @Test
    func numericLookingTextIsQuotedWhenTheColumnTypeIsUnknown() {
        #expect(CompareSQLLiteral.textLiteral("42", columnType: nil, databaseType: .postgresql, driver: driver) == "'42'")
    }

    @Test
    func anIntegerColumnKeepsANumberBare() {
        let positive = CompareSQLLiteral.textLiteral(
            "42", columnType: .integer(rawType: "INT"), databaseType: .mysql, driver: driver
        )
        let negative = CompareSQLLiteral.textLiteral(
            "-17", columnType: .integer(rawType: "INT"), databaseType: .mysql, driver: driver
        )

        #expect(positive == "42")
        #expect(negative == "-17")
    }

    @Test
    func aDecimalColumnKeepsANumberBare() {
        let literal = CompareSQLLiteral.textLiteral(
            "3.50", columnType: .decimal(rawType: "NUMERIC(10,2)"), databaseType: .postgresql, driver: driver
        )

        #expect(literal == "3.50")
    }

    @Test
    func textThatIsNotANumberIsQuotedEvenForANumericColumn() {
        let literal = CompareSQLLiteral.textLiteral(
            "abc", columnType: .integer(rawType: "INT"), databaseType: .postgresql, driver: driver
        )

        #expect(literal == "'abc'")
    }

    @Test
    func sQLServerKeepsItsPrefixOnQuotedText() {
        #expect(CompareSQLLiteral.textLiteral(
                "007", columnType: .text(rawType: "NVARCHAR(10)"), databaseType: .mssql, driver: driver
            ) == "N'007'")
        #expect(CompareSQLLiteral.textLiteral("O'Hara", columnType: nil, databaseType: .mssql, driver: driver) == "N'O''Hara'")
    }

    @Test
    func sQLServerLeavesABareNumberUnprefixed() {
        let literal = CompareSQLLiteral.textLiteral(
            "42", columnType: .integer(rawType: "INT"), databaseType: .mssql, driver: driver
        )

        #expect(literal == "42")
    }

    @Test
    func literalRoutesNullAndTextThroughTheSameRules() {
        #expect(CompareSQLLiteral.literal(
                for: .null, columnType: .text(rawType: "TEXT"), databaseType: .mssql, driver: driver
            ) == "NULL")
        #expect(CompareSQLLiteral.literal(
                for: .text("007"), columnType: .text(rawType: "CHAR(3)"), databaseType: .mysql, driver: driver
            ) == "'007'")
    }

    // #3777: the PluginKit default left a backslash single, which ClickHouse reads as an escape.
    @Test
    func clickHouseTextGoesThroughTheDriversOwnEscaper() {
        let clickHouse = BackslashEscapingDriver()

        #expect(CompareSQLLiteral.textLiteral(#"C:\new"#, columnType: nil, databaseType: .clickhouse, driver: clickHouse)
            == #"'C:\\new'"#)
        #expect(CompareSQLLiteral.textLiteral(#"x\' OR 1=1 --"#, columnType: nil, databaseType: .clickhouse, driver: clickHouse)
            == #"'x\\'' OR 1=1 --'"#)
        #expect(CompareSQLLiteral.textLiteral("42", columnType: .integer(rawType: "UInt8"), databaseType: .clickhouse, driver: clickHouse)
            == "42")
    }
}

private final class BackslashEscapingDriver: PluginDriverStub, @unchecked Sendable {
    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
    }
}

struct DataCompareOptionsDecodingTests {
    private func decode(_ json: String) throws -> DataCompareOptions {
        try JSONDecoder().decode(DataCompareOptions.self, from: Data(json.utf8))
    }

    @Test
    func anObjectWithOneKeyFillsTheRestWithDefaults() throws {
        let options = try decode(#"{"insertMissingRows": false}"#)

        #expect(!options.insertMissingRows)
        #expect(options.updateDifferingRows)
        #expect(!options.deleteExtraRows)
        #expect(options.floatTolerance == 0)
        #expect(options.timestampFractionalDigits == 6)
        #expect(options.maxRetainedEntries == 5_000)
        #expect(options.maxRetainedIdenticalEntries == 1_000)
    }

    @Test
    func anEmptyObjectDecodesToTheDefaults() throws {
        #expect(try decode("{}") == .default)
    }

    /// Key columns and excluded columns moved to each table's own scope. A profile written before
    /// that still carries them, and decoding must step over them rather than fail.
    @Test
    func retiredKeysAreIgnored() throws {
        let json = #"{"keyColumns": ["id"], "excludedFromComparison": ["updated_at"], "deleteExtraRows": true}"#

        let options = try decode(json)

        var expected = DataCompareOptions()
        expected.deleteExtraRows = true
        #expect(options == expected)
    }

    @Test
    func encodingWritesTheCurrentKeysOnly() throws {
        let data = try JSONEncoder().encode(DataCompareOptions.default)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == [
                "insertMissingRows", "updateDifferingRows", "deleteExtraRows", "floatTolerance",
                "timestampFractionalDigits", "maxRetainedEntries", "maxRetainedIdenticalEntries"
            ])
    }

    @Test
    func encodingThenDecodingRoundTrips() throws {
        var options = DataCompareOptions()
        options.insertMissingRows = false
        options.updateDifferingRows = false
        options.deleteExtraRows = true
        options.floatTolerance = 0.001
        options.timestampFractionalDigits = 3
        options.maxRetainedEntries = 10
        options.maxRetainedIdenticalEntries = 2

        let decoded = try JSONDecoder().decode(DataCompareOptions.self, from: JSONEncoder().encode(options))

        #expect(decoded == options)
    }

    @Test
    func writesRowsFollowsTheThreeToggles() {
        var options = DataCompareOptions()
        options.insertMissingRows = true
        options.updateDifferingRows = false
        options.deleteExtraRows = true

        #expect(options.writesRows(of: .insert))
        #expect(!options.writesRows(of: .update))
        #expect(options.writesRows(of: .delete))
        #expect(!options.writesRows(of: .identical))
        #expect(!options.writesRows(of: .conflict))
    }
}

struct CompareSyncProfileScopeCodingTests {
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
    @Test
    func aProfileSavedBeforeTableScopesKeepsItsExcludedColumns() throws {
        let decoded = try JSONDecoder().decode(
            CompareSyncProfile.self, from: legacyProfileJSON(dataOptions: legacyDataOptions)
        )

        #expect(decoded.id == profileId)
        #expect(decoded.name == "Nightly")
        #expect(decoded.mode == .data)
        #expect(decoded.source.database == "prod")
        #expect(decoded.source.schema == "public")
        #expect(decoded.target.schema == nil)
        #expect(decoded.tableScopes == [:])
        #expect(decoded.legacyExcludedColumns == ["updated_at"])
        #expect(!decoded.dataOptions.updateDifferingRows)
        #expect(decoded.dataOptions.deleteExtraRows)
        #expect(decoded.structureOptions == .default)
        #expect(decoded.selectedObjects == ["orders"])
    }

    @Test
    func aProfileWithNoDataOptionsCarriesNoLegacyExclusions() throws {
        let decoded = try JSONDecoder().decode(
            CompareSyncProfile.self, from: legacyProfileJSON(dataOptions: nil)
        )

        #expect(decoded.dataOptions == .default)
        #expect(decoded.legacyExcludedColumns.isEmpty)
        #expect(decoded.tableScopes == [:])
    }

    @Test
    func tableScopesRoundTrip() throws {
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

        #expect(decoded.tableScopes == original.tableScopes)
        #expect(decoded.tableScopes[key]?.rowLimit == 500)
        #expect(decoded.tableScopes[key]?.targetFilter == "")
        #expect(decoded == original)
    }

    /// Saving or deleting any one comparison rewrites the whole stored array, so a comparison the
    /// user has not opened yet keeps the columns it was told to leave out. They move onto its table
    /// scopes the first time its tables load, and the session stops writing them from then on.
    @Test
    func legacyExcludedColumnsSurviveARewriteUntilTheTablesLoad() throws {
        let data = try JSONEncoder().encode(profile(tableScopes: [:], legacy: ["updated_at"]))

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["legacyExcludedColumns"] as? [String]) == ["updated_at"])
        let dataOptions = try #require(object["dataOptions"] as? [String: Any])
        #expect(dataOptions["excludedFromComparison"] == nil, "the option they used to live in is gone")

        let decoded = try JSONDecoder().decode(CompareSyncProfile.self, from: data)
        #expect(decoded.legacyExcludedColumns == ["updated_at"])
    }
}
