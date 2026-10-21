import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct DatabaseSearchQueryTests {
    private typealias Column = DatabaseSearchColumnPlanner.Column

    private static let postgres = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit
    )

    private static let sqlServer = SQLDialectDescriptor(
        identifierQuote: "[", keywords: [], functions: [], dataTypes: [],
        booleanLiteralStyle: .numeric, likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch, autoLimitStyle: .top
    )

    private static let columns = [
        Column(name: "email", type: .text(rawType: "varchar")),
        Column(name: "id", type: .integer(rawType: "int"))
    ]

    private static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func build(
        _ term: String,
        target: DatabaseSearchTarget = DatabaseSearchTarget(name: "users", schema: "app"),
        columns: [Column] = Self.columns,
        dialect: SQLDialectDescriptor = Self.postgres,
        rowCap: Int = 1_000
    ) -> DatabaseSearchQuery? {
        let filters = DatabaseSearchColumnPlanner.filters(
            for: columns,
            options: DatabaseSearchOptions(term: term),
            engine: DatabaseSearchColumnPlanner.Engine(family: .postgres, castsToText: true)
        )
        return DatabaseSearchQuery.build(
            target: target,
            columns: columns,
            filters: filters,
            rowCap: rowCap,
            databaseType: .postgresql,
            dialect: dialect,
            quoteIdentifier: Self.quote,
            driver: nil
        )
    }

    @Test("One flag per searched column, the columns joined with OR, and one row past the cap")
    func flagsPerColumnAndCap() throws {
        let query = try #require(build("42"))
        #expect(query.filters.map(\.columnName) == ["email", "id"])
        #expect(query.sql.hasPrefix("SELECT CASE WHEN "))
        #expect(query.sql.contains("THEN 1 ELSE 0 END AS m1, CASE WHEN "))
        #expect(query.sql.contains("FROM \"app\".\"users\" WHERE ("))
        #expect(query.sql.contains(") OR (\"id\" = 42)"))
        #expect(query.sql.hasSuffix(" LIMIT 1001"))
    }

    @Test("LIKE wildcards and quotes in the value are escaped, identifiers are quoted")
    func valueAndIdentifiersAreEscaped() throws {
        let columns = [Column(name: "na\"me", type: .text(rawType: "text"))]
        let query = try #require(build("50%_off's", target: DatabaseSearchTarget(name: "odd\"table", schema: nil), columns: columns))
        #expect(query.sql.contains("\"na\"\"me\""))
        #expect(query.sql.contains("FROM \"odd\"\"table\" WHERE"))
        #expect(query.sql.contains("50!%!_off''s"))
        #expect(query.sql.contains("ESCAPE '!'"))
    }

    @Test("An engine that cannot say LIMIT gets its own row cap")
    func offsetFetchEngineCapsWithTop() throws {
        let query = try #require(build("ada", dialect: Self.sqlServer))
        #expect(query.sql.contains("OFFSET 0 ROWS FETCH NEXT 1001 ROWS ONLY"))
        #expect(!query.sql.contains("LIMIT"))
    }

    @Test("No searchable column builds no query")
    func noColumnsNoQuery() {
        #expect(build("ada", columns: [Column(name: "id", type: .integer(rawType: "int"))]) == nil)
    }

    @Test("The rows say which columns matched and how many rows")
    func matchReadsTheFlags() throws {
        let query = try #require(build("42", rowCap: 3))
        let match = try #require(query.match(from: [["0", "1"], ["0", "1"]]))
        #expect(match.matchedColumns == ["id"])
        #expect(match.rowCount == 2)
        #expect(match.isCapped == false)
        #expect(query.match(from: []) == nil)
    }

    @Test("A row past the cap marks the count as capped and stops counting at the cap")
    func capIsReported() throws {
        let query = try #require(build("42", rowCap: 2))
        let match = try #require(query.match(from: [["1", "0"], ["1", "0"], ["0", "1"]]))
        #expect(match.rowCount == 2)
        #expect(match.isCapped)
        #expect(match.matchedColumns == ["email"])
    }

    @Test("Flags read as numbers, booleans or bytes")
    func flagSpellings() throws {
        let query = try #require(build("42"))
        let match = try #require(query.match(from: [["true", .bytes(Data([1]))], ["0.0", nil]]))
        #expect(match.matchedColumns == ["email", "id"])
    }

    @Test("The tab opens on the matched columns, or every searched one when the count was capped")
    func filterStateFollowsTheCap() throws {
        let query = try #require(build("42", rowCap: 5))
        let exact = try #require(query.match(from: [["0", "1"]]))
        #expect(exact.filterState.filters.map(\.columnName) == ["id"])
        #expect(exact.filterState.filterLogicMode == .or)
        #expect(exact.filterState.appliedFilters.map(\.columnName) == ["id"])

        let capped = try #require(DatabaseSearchQuery(sql: "", filters: query.filters, rowCap: 1).match(from: [["0", "1"], ["0", "1"]]))
        #expect(capped.filterState.filters.map(\.columnName) == ["email", "id"])
    }
}
