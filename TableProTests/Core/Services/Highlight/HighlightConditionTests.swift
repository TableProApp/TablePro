//
//  HighlightConditionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Highlight condition matching")
struct HighlightConditionTests {
    private func matches(
        _ value: PluginCellValue,
        _ filterOperator: FilterOperator,
        _ operand: String = "",
        second: String? = nil,
        caseSensitive: Bool? = nil,
        type: ColumnType? = .text(rawType: "VARCHAR")
    ) -> Bool {
        let rule = HighlightRule(
            columnName: "c",
            filterOperator: filterOperator,
            value: operand,
            secondValue: second,
            isCaseSensitive: caseSensitive
        )
        return HighlightCondition(rule: rule, columnType: type).matches(value)
    }

    @Test("Equality on text is exact and case-sensitive by default")
    func textEquality() {
        #expect(matches("paid", .equal, "paid"))
        #expect(!matches("Paid", .equal, "paid"))
        #expect(matches("Paid", .equal, "paid", caseSensitive: false))
        #expect(matches("pending", .notEqual, "paid"))
        #expect(!matches("007", .equal, "7"))
    }

    @Test("A padded value matches exactly as stored, so a quick rule matches its own cell")
    func paddedValuesMatchAsStored() {
        #expect(matches("abc       ", .equal, "abc       ", type: .text(rawType: "CHAR(10)")))
        #expect(!matches("abc", .equal, "abc       ", type: .text(rawType: "CHAR(10)")))
        #expect(matches("   ", .equal, "   "))
        #expect(matches("42", .equal, " 42 ", type: .integer(rawType: "INT")))
    }

    @Test("NULL fails every comparison and matches only IS NULL and IS EMPTY")
    func nullSemantics() {
        #expect(matches(.null, .isNull))
        #expect(matches(.null, .isEmpty))
        #expect(!matches(.null, .isNotNull))
        #expect(!matches(.null, .notEqual, "paid"))
        #expect(!matches(.null, .greaterThan, "1", type: .integer(rawType: "INT")))
        #expect(!matches(.null, .notContains, "x"))
        #expect(!matches(.null, .notInList, "a, b"))
    }

    @Test("The literal NULL means IS NULL on a column that is not text")
    func nullLiteral() {
        #expect(matches(.null, .equal, "NULL", type: .integer(rawType: "INT")))
        #expect(!matches("5", .equal, "NULL", type: .integer(rawType: "INT")))
        #expect(matches("5", .notEqual, "null", type: .integer(rawType: "INT")))
        #expect(!matches(.null, .equal, "NULL"))
        #expect(matches("NULL", .equal, "NULL"))
    }

    @Test("Numbers compare numerically on a numeric column")
    func numericColumns() {
        let integer = ColumnType.integer(rawType: "INT")
        #expect(matches("1000", .greaterThan, "999", type: integer))
        #expect(matches("1.0", .equal, "1", type: .decimal(rawType: "DECIMAL")))
        #expect(matches("5", .between, "1", second: "10", type: integer))
        #expect(!matches("11", .between, "1", second: "10", type: integer))
        #expect(matches("10", .lessOrEqual, "10", type: integer))
    }

    @Test("Ordering on text compares numerically only when both sides are numbers")
    func orderingOnText() {
        #expect(matches("1000", .greaterThan, "999"))
        #expect(matches("banana", .greaterThan, "apple"))
        #expect(!matches("apple", .greaterThan, "banana"))
    }

    @Test("Boolean columns accept every spelling of true and false")
    func booleans() {
        let boolean = ColumnType.boolean(rawType: "BOOLEAN")
        #expect(matches("t", .equal, "true", type: boolean))
        #expect(matches("1", .equal, "yes", type: boolean))
        #expect(matches("false", .equal, "0", type: boolean))
        #expect(!matches("f", .equal, "true", type: boolean))
        #expect(matches("1", .equal, "true", type: .integer(rawType: "TINYINT(1)")))
    }

    @Test("Pattern operators ignore case by default and honour Match Case")
    func patterns() {
        #expect(matches("Hello World", .contains, "world"))
        #expect(!matches("Hello World", .contains, "world", caseSensitive: true))
        #expect(matches("Hello", .startsWith, "he"))
        #expect(matches("Hello", .endsWith, "LLO"))
        #expect(!matches("Hello", .endsWith, "hel"))
        #expect(matches("Hello", .notContains, "xyz"))
    }

    @Test("Empty means NULL or an empty string on text, and only NULL elsewhere")
    func emptiness() {
        #expect(matches("", .isEmpty))
        #expect(!matches("x", .isEmpty))
        #expect(matches("x", .isNotEmpty))
        #expect(!matches("", .isNotEmpty))
        #expect(!matches("", .isEmpty, type: .integer(rawType: "INT")))
        #expect(matches("", .isNotEmpty, type: .integer(rawType: "INT")))
    }

    @Test("IN and NOT IN split on commas and trim each item")
    func lists() {
        #expect(matches("b", .inList, "a, b ,c"))
        #expect(!matches("d", .inList, "a, b, c"))
        #expect(matches("d", .notInList, "a, b, c"))
        #expect(!matches("a", .notInList, "a, b"))
        #expect(matches(.null, .inList, "a, NULL", type: .integer(rawType: "INT")))
    }

    @Test("A regular expression searches the value, and an invalid one matches nothing")
    func regex() {
        #expect(matches("order-42", .regex, "\\d+$"))
        #expect(!matches("order", .regex, "\\d+$"))
        #expect(matches("ABC", .regex, "abc", caseSensitive: false))
        #expect(!matches("anything", .regex, "(unclosed"))
    }

    @Test("A binary value matches only IS NULL and IS NOT NULL")
    func binary() {
        let bytes = PluginCellValue.bytes(Data([0x01, 0x02]))
        #expect(matches(bytes, .isNotNull))
        #expect(!matches(bytes, .isNull))
        #expect(!matches(bytes, .equal, "0x0102"))
        #expect(!matches(bytes, .contains, "01"))
    }

    @Test("A search past the cap only looks at the leading part of a very long value")
    func searchIsCapped() {
        let long = String(repeating: "a", count: HighlightCondition.searchLimit + 50) + "needle"
        #expect(!matches(.text(long), .contains, "needle"))
        #expect(matches(.text("needle" + long), .contains, "needle"))
    }
}
