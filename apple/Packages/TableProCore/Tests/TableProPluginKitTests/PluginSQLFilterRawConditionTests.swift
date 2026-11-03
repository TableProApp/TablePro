//
//  PluginSQLFilterRawConditionTests.swift
//  TableProPluginKitTests
//

@testable import TableProPluginKit
import Testing

// A driver that writes its own SQL gets the reader's raw condition under the `__RAW__` column. Read as a
// column it became `[__RAW__] = N'...'`, which the server rejects as an unknown column.
struct PluginSQLFilterRawConditionTests {
    private static func bracket(_ name: String) -> String { "[\(name)]" }

    @Test("A raw row is written as its own grouped condition, whatever operator it last showed", arguments: [
        "=", "CONTAINS", "IS NULL",
    ])
    func rawRowIsGroupedCondition(op: String) {
        let condition = PluginSQLFilter.buildFilterCondition(
            column: "__RAW__", op: op, value: "id > 1 OR id < 0", kind: nil,
            quoteIdentifier: Self.bracket,
            escapeTypedValue: { value, _ in "'\(value)'" },
            regexCondition: { _, _ in nil }
        )
        #expect(condition == "(id > 1 OR id < 0)")
    }

    @Test("The case-aware builder writes a raw row the same way")
    func caseAwareBuilderWritesRawRow() {
        let clause = PluginSQLFilter.buildWhereClause(
            filters: [
                PluginQueryFilter(column: "__RAW__", op: "=", value: "total > 10"),
                PluginQueryFilter(column: "name", op: "=", value: "bob"),
            ],
            logicMode: "and",
            columnKinds: [:],
            caseSensitivityStyle: .caseFoldFunction,
            quoteIdentifier: Self.bracket,
            escapeTypedValue: { value, _ in "'\(value)'" },
            regexCondition: { _, _, _ in nil }
        )
        #expect(clause.hasPrefix("(total > 10) AND "))
        #expect(!clause.contains("__RAW__"))
    }

    @Test("A raw row holding only whitespace writes nothing")
    func blankRawRowWritesNothing() {
        let condition = PluginSQLFilter.buildFilterCondition(
            column: "__RAW__", op: "=", value: " \n",
            quoteIdentifier: Self.bracket,
            escapeValue: { "'\($0)'" },
            regexCondition: { _, _ in nil }
        )
        #expect(condition == nil)
    }
}
