//
//  FilterCaseSensitivityPersistenceTests.swift
//  TableProTests
//
//  Round-tripping filters saved before case sensitivity existed (#2048)
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Filter Case Sensitivity Persistence")
struct FilterCaseSensitivityPersistenceTests {

    private func decode(_ json: String) throws -> TableFilter {
        try JSONDecoder().decode(TableFilter.self, from: Data(json.utf8))
    }

    @Test("A saved pattern filter with no case key decodes to ignore case")
    func testLegacyPatternFilterDecodes() throws {
        let filter = try decode("""
        {"id":"8B9E4F1C-2A3D-4B5E-9F60-1234567890AB","columnName":"name",
         "filterOperator":"CONTAINS","value":"smith","isEnabled":true}
        """)
        #expect(filter.filterOperator == .contains)
        #expect(filter.isCaseSensitive == false)
    }

    @Test("A saved equals filter with no case key decodes to match case")
    func testLegacyEqualsFilterDecodes() throws {
        let filter = try decode("""
        {"id":"8B9E4F1C-2A3D-4B5E-9F60-1234567890AB","columnName":"name",
         "filterOperator":"=","value":"smith","isEnabled":true}
        """)
        #expect(filter.isCaseSensitive)
    }

    @Test("An explicit case key wins over the operator default")
    func testExplicitKeyWins() throws {
        let filter = try decode("""
        {"id":"8B9E4F1C-2A3D-4B5E-9F60-1234567890AB","columnName":"name",
         "filterOperator":"CONTAINS","value":"smith","isEnabled":true,"isCaseSensitive":true}
        """)
        #expect(filter.isCaseSensitive)
    }

    @Test("A filter round-trips through JSON unchanged")
    func testRoundTrip() throws {
        let original = TableFilter(
            columnName: "name", filterOperator: .startsWith, value: "s", isCaseSensitive: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TableFilter.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isCaseSensitive)
    }

    @Test("Every preset in a batch survives when one carries the new key")
    func testPresetBatchDecodes() throws {
        let json = """
        [{"id":"8B9E4F1C-2A3D-4B5E-9F60-1234567890AB","columnName":"a",
          "filterOperator":"CONTAINS","value":"x","isEnabled":true},
         {"id":"9B9E4F1C-2A3D-4B5E-9F60-1234567890AB","columnName":"b",
          "filterOperator":"CONTAINS","value":"y","isEnabled":true,"isCaseSensitive":true}]
        """
        let filters = try JSONDecoder().decode([TableFilter].self, from: Data(json.utf8))
        #expect(filters.count == 2)
        #expect(filters[0].isCaseSensitive == false)
        #expect(filters[1].isCaseSensitive)
    }

    @Test("The plugin transfer type carries the row's case setting")
    func testPluginFilterCarriesCase() {
        let filter = TableFilter(columnName: "name", filterOperator: .contains, value: "x")
        #expect(filter.asPluginQueryFilter.isCaseSensitive == false)

        let exact = TableFilter(columnName: "name", filterOperator: .equal, value: "x")
        #expect(exact.asPluginQueryFilter.isCaseSensitive)
    }

    @Test("A dialect built with the pre-existing initializer reports no case support")
    func testLegacyDialectInitializerDefaults() {
        let dialect = SQLDialectDescriptor(
            identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
            regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit, paginationStyle: .limit,
            offsetFetchOrderBy: "ORDER BY 1", requiresBackslashEscaping: false,
            autoLimitStyle: .limit
        )
        #expect(dialect.caseSensitivityStyle == .unsupported)
        #expect(dialect.caseFoldFunction == "LOWER")
        #expect(PluginSQLCaseFolding.isAdjustable(style: dialect.caseSensitivityStyle) == false)
    }

    @Test("Copying a dialect keeps every other field")
    func testWithCaseSensitivityStylePreservesFields() {
        let base = SQLDialectDescriptor(
            identifierQuote: "`", keywords: ["SELECT"], functions: ["NOW"], dataTypes: ["INT"],
            tableOptions: ["ENGINE="], regexSyntax: .regexp, booleanLiteralStyle: .numeric,
            likeEscapeStyle: .implicit, paginationStyle: .limit,
            requiresBackslashEscaping: true, autoLimitStyle: .top
        )
        let copy = base.withCaseSensitivityStyle(.caseFoldFunction, caseFoldFunction: "lowerUTF8")
        #expect(copy.caseSensitivityStyle == .caseFoldFunction)
        #expect(copy.caseFoldFunction == "lowerUTF8")
        #expect(copy.identifierQuote == "`")
        #expect(copy.keywords == ["SELECT"])
        #expect(copy.tableOptions == ["ENGINE="])
        #expect(copy.regexSyntax == .regexp)
        #expect(copy.likeEscapeStyle == .implicit)
        #expect(copy.requiresBackslashEscaping)
        #expect(copy.autoLimitStyle == .top)
    }
}
