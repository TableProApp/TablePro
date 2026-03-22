//
//  RowSortComparatorTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("RowSortComparator")
struct RowSortComparatorTests {
    @Test("numeric string ordering treats 10 > 2")
    func numericOrdering() {
        let result = RowSortComparator.compare("10", "2", columnType: nil)
        #expect(result == .orderedDescending)
    }

    @Test("integer column uses Int64 comparison")
    func integerColumn() {
        let result = RowSortComparator.compare("-5", "3", columnType: .integer(rawType: "INT"))
        #expect(result == .orderedAscending)
    }

    @Test("integer column with large values")
    func integerLargeValues() {
        let result = RowSortComparator.compare("999999999", "1000000000", columnType: .integer(rawType: "BIGINT"))
        #expect(result == .orderedAscending)
    }

    @Test("integer column with non-numeric falls back to string")
    func integerFallback() {
        let result = RowSortComparator.compare("abc", "def", columnType: .integer(rawType: "INT"))
        #expect(result == .orderedAscending)
    }

    @Test("decimal column uses Double comparison")
    func decimalColumn() {
        let result = RowSortComparator.compare("1.5", "2.3", columnType: .decimal(rawType: "DECIMAL"))
        #expect(result == .orderedAscending)
    }

    @Test("decimal column negative values")
    func decimalNegative() {
        let result = RowSortComparator.compare("-1.5", "0.5", columnType: .decimal(rawType: "FLOAT"))
        #expect(result == .orderedAscending)
    }

    @Test("equal values return orderedSame")
    func equalValues() {
        let result = RowSortComparator.compare("hello", "hello", columnType: nil)
        #expect(result == .orderedSame)
    }

    @Test("empty strings are equal")
    func emptyStrings() {
        let result = RowSortComparator.compare("", "", columnType: nil)
        #expect(result == .orderedSame)
    }

    @Test("text column uses numeric string comparison")
    func textColumn() {
        let result = RowSortComparator.compare("file2", "file10", columnType: .text(rawType: "VARCHAR"))
        #expect(result == .orderedAscending)
    }

    @Test("nil column type uses numeric string comparison")
    func nilColumnType() {
        let result = RowSortComparator.compare("10", "2", columnType: nil)
        #expect(result == .orderedDescending)
    }
}
