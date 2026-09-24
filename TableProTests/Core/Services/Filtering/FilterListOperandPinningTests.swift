//
//  FilterListOperandPinningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Filter list operand call sites")
struct FilterListOperandPinningTests {
    private static let mysql = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexp, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit
    )

    private static let text = ColumnType.text(rawType: "VARCHAR")
    private static let integer = ColumnType.integer(rawType: "INT")

    private func sql(_ filterOperator: FilterOperator, _ value: String, type: ColumnType?) -> String? {
        let generator = FilterSQLGenerator(
            dialect: Self.mysql,
            columns: type == nil ? [] : ["c"],
            columnTypes: type.map { [$0] } ?? []
        )
        return generator.generateCondition(
            from: TestFixtures.makeTableFilter(column: "c", op: filterOperator, value: value)
        )
    }

    private func highlights(
        _ cell: PluginCellValue,
        _ filterOperator: FilterOperator,
        _ value: String,
        type: ColumnType?
    ) -> Bool {
        let rule = HighlightRule(columnName: "c", filterOperator: filterOperator, value: value)
        return HighlightCondition(rule: rule, columnType: type).matches(cell)
    }

    @Test("The SQL generator splits IN on every comma and trims spaces and tabs")
    func sqlGeneratorListSplitting() {
        let cases: [(value: String, type: ColumnType?, expected: String?)] = [
            ("a, b ,c", Self.text, "`c` IN ('a', 'b', 'c')"),
            ("a,,b", Self.text, "`c` IN ('a', 'b')"),
            ("\ta\t,b", Self.text, "`c` IN ('a', 'b')"),
            (" , ", Self.text, nil),
            ("", Self.text, nil),
            ("a,b", Self.text, "`c` IN ('a', 'b')"),
            ("'a','b'", Self.text, "`c` IN ('''a''', '''b''')"),
            ("a,\nb", Self.text, "`c` IN ('a', '\nb')"),
            (" 1 , 2 ", Self.integer, "`c` IN (1, 2)"),
            ("1, NULL", Self.integer, "(`c` IN (1) OR `c` IS NULL)"),
            ("null", Self.integer, "`c` IS NULL"),
            ("1, NULL", Self.text, "`c` IN ('1', 'NULL')"),
            ("1, NULL", nil, "(`c` IN (1) OR `c` IS NULL)")
        ]
        for testCase in cases {
            #expect(sql(.inList, testCase.value, type: testCase.type) == testCase.expected, "\(testCase.value)")
        }
    }

    @Test("NOT IN with a NULL item keeps rows that are neither in the list nor NULL")
    func sqlGeneratorNegatedList() {
        let cases: [(value: String, type: ColumnType?, expected: String?)] = [
            ("a, b", Self.text, "`c` NOT IN ('a', 'b')"),
            ("1, NULL", Self.integer, "(`c` NOT IN (1) AND `c` IS NOT NULL)"),
            ("NULL", Self.integer, "`c` IS NOT NULL"),
            (" ,, ", Self.integer, nil)
        ]
        for testCase in cases {
            #expect(sql(.notInList, testCase.value, type: testCase.type) == testCase.expected, "\(testCase.value)")
        }
    }

    @Test("Highlighting splits IN on every comma and trims spaces and tabs")
    func highlightListSplitting() {
        let cases: [(cell: PluginCellValue, value: String, type: ColumnType?, expected: Bool)] = [
            ("b", "a, b ,c", Self.text, true),
            ("b", "a,,b", Self.text, true),
            ("a", "\ta\t,b", Self.text, true),
            ("", " , ", Self.text, false),
            ("a,b", "a,b", Self.text, false),
            ("a", "'a','b'", Self.text, false),
            ("'a'", "'a','b'", Self.text, true),
            ("b", "a,\nb", Self.text, false),
            ("2", " 1 , 2 ", Self.integer, true),
            ("2.0", "1,2", Self.integer, true),
            (.null, "1, NULL", Self.integer, true),
            (.null, "1, NULL", Self.text, false),
            ("NULL", "1, NULL", Self.text, true),
            (.null, "1, NULL", nil, true)
        ]
        for testCase in cases {
            #expect(
                highlights(testCase.cell, .inList, testCase.value, type: testCase.type) == testCase.expected,
                "\(testCase.cell) IN \(testCase.value)"
            )
        }
    }

    @Test("Highlighting NOT IN ignores NULL items and matches nothing when no value is left")
    func highlightNegatedList() {
        let cases: [(cell: PluginCellValue, value: String, type: ColumnType?, expected: Bool)] = [
            ("c", "a, b", Self.text, true),
            ("a", "a, b", Self.text, false),
            ("3", "1, NULL", Self.integer, true),
            ("1", "1, NULL", Self.integer, false),
            ("3", "NULL", Self.integer, false),
            ("x", " , ", Self.text, false),
            (.null, "a, b", Self.text, false)
        ]
        for testCase in cases {
            #expect(
                highlights(testCase.cell, .notInList, testCase.value, type: testCase.type) == testCase.expected,
                "\(testCase.cell) NOT IN \(testCase.value)"
            )
        }
    }
}
