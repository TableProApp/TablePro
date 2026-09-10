import Foundation
import TableProModels
import TableProPluginKit
import Testing
@testable import TableProQuery

@Suite("Mobile Filter Case Sensitivity")
struct MobileFilterSQLGeneratorCaseSensitivityTests {

    private static let postgresql = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        likeEscapeStyle: .explicit, caseSensitivityStyle: .ilikeOperator
    )

    private static let oracle = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        likeEscapeStyle: .explicit, caseSensitivityStyle: .caseFoldFunction
    )

    private static let mysql = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        likeEscapeStyle: .implicit, caseSensitivityStyle: .collationDefined
    )

    private func clause(
        _ dialect: SQLDialectDescriptor,
        _ filterOperator: FilterOperator,
        value: String = "smith",
        isCaseSensitive: Bool? = nil
    ) -> String {
        FilterSQLGenerator(dialect: dialect).generateWhereClause(
            from: [TableFilter(
                columnName: "name",
                filterOperator: filterOperator,
                value: value,
                isCaseSensitive: isCaseSensitive
            )],
            logicMode: .and
        )
    }

    @Test("Pattern operators ignore case by default")
    func testPatternDefaults() {
        #expect(TableFilter(filterOperator: .contains).isCaseSensitive == false)
        #expect(TableFilter(filterOperator: .like).isCaseSensitive == false)
        #expect(TableFilter(filterOperator: .equal).isCaseSensitive)
    }

    @Test("PostgreSQL contains ignoring case uses ILIKE")
    func testPostgresContains() {
        #expect(clause(Self.postgresql, .contains) == "WHERE \"name\" ILIKE '%smith%' ESCAPE '!'")
    }

    @Test("PostgreSQL contains matching case keeps LIKE")
    func testPostgresContainsMatchingCase() {
        #expect(clause(Self.postgresql, .contains, isCaseSensitive: true) == "WHERE \"name\" LIKE '%smith%' ESCAPE '!'")
    }

    @Test("Oracle contains ignoring case folds both sides")
    func testOracleContains() {
        #expect(clause(Self.oracle, .contains) == "WHERE LOWER(\"name\") LIKE LOWER('%smith%') ESCAPE '!'")
    }

    @Test("MySQL emits the same SQL whichever way the row is set")
    func testMySQLUnchanged() {
        #expect(clause(Self.mysql, .contains) == clause(Self.mysql, .contains, isCaseSensitive: true))
    }

    @Test("Equals ignoring case folds both sides")
    func testEqualsIgnoringCase() {
        #expect(clause(Self.postgresql, .equal, isCaseSensitive: false) == "WHERE LOWER(\"name\") = LOWER('smith')")
    }

    @Test("Equals matching case stays untouched")
    func testEqualsMatchingCase() {
        #expect(clause(Self.postgresql, .equal) == "WHERE \"name\" = 'smith'")
    }

    @Test("IN ignoring case folds the column and every value")
    func testInListIgnoringCase() {
        let sql = clause(Self.postgresql, .in, value: "a,b", isCaseSensitive: false)
        #expect(sql == "WHERE LOWER(\"name\") IN (LOWER('a'), LOWER('b'))")
    }

    @Test("A saved filter with no case key decodes to the operator default")
    func testLegacyDecode() throws {
        let json = """
        {"id":"8B9E4F1C-2A3D-4B5E-9F60-1234567890AB","columnName":"name",
         "filterOperator":"contains","value":"smith","secondValue":"","isEnabled":true}
        """
        let filter = try JSONDecoder().decode(TableFilter.self, from: Data(json.utf8))
        #expect(filter.isCaseSensitive == false)
    }
}
