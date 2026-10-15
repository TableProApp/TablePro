//
//  ClickHouseGeneratedColumnClassificationTests.swift
//  TableProTests
//

import Testing

struct ClickHouseGeneratedColumnClassificationTests {
    @Test("MATERIALIZED and ALIAS columns are generated", arguments: ["MATERIALIZED", "ALIAS"])
    func generatedKinds(_ defaultKind: String) {
        #expect(clickhouseColumnIsGenerated(defaultKind: defaultKind))
    }

    @Test("DEFAULT columns stay insertable")
    func defaultKind() {
        #expect(!clickhouseColumnIsGenerated(defaultKind: "DEFAULT"))
    }

    @Test("An ordinary column reports no kind")
    func ordinaryColumn() {
        #expect(!clickhouseColumnIsGenerated(defaultKind: ""))
        #expect(!clickhouseColumnIsGenerated(defaultKind: nil))
    }

    @Test("Case and padding do not change the classification")
    func caseAndPadding() {
        #expect(clickhouseColumnIsGenerated(defaultKind: "materialized"))
        #expect(clickhouseColumnIsGenerated(defaultKind: " ALIAS "))
    }
}
