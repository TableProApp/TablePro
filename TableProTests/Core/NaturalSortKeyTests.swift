//
//  NaturalSortKeyTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("naturalSortKey")
struct NaturalSortKeyTests {
    @Test("Pure-digit values sort by magnitude, not lexically")
    func pureDigitsSortByMagnitude() {
        let values = ["2", "10", "100", "11"]
        let sorted = values.map(naturalSortKey).enumerated()
            .sorted { $0.element < $1.element }
            .map { values[$0.offset] }
        #expect(sorted == ["2", "10", "11", "100"])
    }

    @Test("Embedded numbers in text sort naturally")
    func embeddedNumbersInText() {
        let values = ["Item 10", "Item 2", "Item 100", "Item 20"]
        let sorted = values.map(naturalSortKey).enumerated()
            .sorted { $0.element < $1.element }
            .map { values[$0.offset] }
        #expect(sorted == ["Item 2", "Item 10", "Item 20", "Item 100"])
    }

    @Test("Comparison is case-insensitive")
    func caseInsensitive() {
        #expect(naturalSortKey("ABC") == naturalSortKey("abc"))
        #expect(naturalSortKey("Foo") == naturalSortKey("foo"))
    }

    @Test("Leading zeros are stripped - '007' and '7' produce same key")
    func leadingZerosStripped() {
        #expect(naturalSortKey("007") == naturalSortKey("7"))
        #expect(naturalSortKey("00042") == naturalSortKey("42"))
    }

    @Test("'0' and any non-zero number produce different keys")
    func zeroOrdersBeforePositives() {
        #expect(naturalSortKey("0") < naturalSortKey("1"))
        #expect(naturalSortKey("0") < naturalSortKey("5"))
    }

    @Test("Empty string produces empty key")
    func emptyKey() {
        #expect(naturalSortKey("") == "")
    }

    @Test("Pure number sorts before text starting with letter")
    func numberBeforeLetter() {
        #expect(naturalSortKey("5") < naturalSortKey("abc"))
    }

    @Test("Mixed runs sort by leading digit run when prefix equal")
    func mixedRuns() {
        #expect(naturalSortKey("file9.txt") < naturalSortKey("file10.txt"))
        #expect(naturalSortKey("v1.2.3") < naturalSortKey("v1.10.0"))
    }
}

@Suite("FilterClause Equatable")
struct FilterClauseEquatableTests {
    @Test("Same content, different id compares equal (spec equality)")
    func differentIdSameContent() {
        let a = FilterClause(id: UUID(), column: 1, op: .contains, value: "x")
        let b = FilterClause(id: UUID(), column: 1, op: .contains, value: "x")
        #expect(a == b)
    }

    @Test("Different column compares unequal even with same id")
    func differentColumn() {
        let id = UUID()
        let a = FilterClause(id: id, column: 1, op: .contains, value: "x")
        let b = FilterClause(id: id, column: 2, op: .contains, value: "x")
        #expect(a != b)
    }

    @Test("Different operator compares unequal")
    func differentOperator() {
        let id = UUID()
        let a = FilterClause(id: id, column: 1, op: .contains, value: "x")
        let b = FilterClause(id: id, column: 1, op: .equals, value: "x")
        #expect(a != b)
    }

    @Test("Different value compares unequal")
    func differentValue() {
        let id = UUID()
        let a = FilterClause(id: id, column: 1, op: .contains, value: "x")
        let b = FilterClause(id: id, column: 1, op: .contains, value: "y")
        #expect(a != b)
    }
}
