//
//  ClickHouseGeneratedColumnClassificationTests.swift
//  TableProTests
//

import Testing

@Suite("ClickHouse Generated Column Classification")
struct ClickHouseGeneratedColumnClassificationTests {
    @Test("MATERIALIZED columns are generated")
    func materialized() {
        #expect(clickhouseColumnIsGenerated(defaultKind: "MATERIALIZED"))
    }

    @Test("ALIAS columns are generated")
    func alias() {
        #expect(clickhouseColumnIsGenerated(defaultKind: "ALIAS"))
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
