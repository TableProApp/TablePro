//
//  RowSortComparatorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

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

    @Test("A boolean column holding integers orders them as numbers")
    func booleanColumnHoldingIntegers() {
        let tinyint = ColumnTypeClassifier(family: .mysql).classify(rawTypeName: "TINYINT(1)")
        #expect(tinyint.isBooleanType)
        #expect(RowSortComparator.compare("-2", "-1", columnType: tinyint) == .orderedAscending)
        #expect(RowSortComparator.compare("10", "9", columnType: tinyint) == .orderedDescending)
        #expect(RowSortComparator.compare("-128", "127", columnType: tinyint) == .orderedAscending)
        #expect(RowSortComparator.compare("0", "1", columnType: tinyint) == .orderedAscending)
        #expect(RowSortComparator.compare("1", "1", columnType: tinyint) == .orderedSame)
    }

    @Test("A boolean column holding true and false orders false first, whatever the spelling")
    func booleanColumnHoldingTruthValues() {
        let boolean = ColumnType.boolean(rawType: "BOOLEAN")
        #expect(RowSortComparator.compare("false", "true", columnType: boolean) == .orderedAscending)
        #expect(RowSortComparator.compare("TRUE", "false", columnType: boolean) == .orderedDescending)
        #expect(RowSortComparator.compare("t", "f", columnType: boolean) == .orderedDescending)
        #expect(RowSortComparator.compare("t", "true", columnType: boolean) == .orderedSame)
    }

    @Test("A boolean column mixing integers and true or false orders them one way")
    func booleanColumnMixingIntegersAndTruthValues() {
        let boolean = ColumnType.boolean(rawType: "BOOLEAN")
        #expect(RowSortComparator.compare("1", "2", columnType: boolean) == .orderedAscending)
        #expect(RowSortComparator.compare("2", "true", columnType: boolean) == .orderedDescending)
        #expect(RowSortComparator.compare("true", "1", columnType: boolean) == .orderedSame)
        #expect(RowSortComparator.compare("false", "-1", columnType: boolean) == .orderedDescending)
    }

    @Test("text column uses numeric string comparison")
    func textColumn() {
        let result = RowSortComparator.compare("file2", "file10", columnType: .text(rawType: "VARCHAR"))
        #expect(result == .orderedAscending)
    }
}
