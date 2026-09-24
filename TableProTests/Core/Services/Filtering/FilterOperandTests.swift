//
//  FilterOperandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Filter operand")
struct FilterOperandTests {
    private static let text = ColumnType.text(rawType: "VARCHAR")
    private static let integer = ColumnType.integer(rawType: "INT")

    @Test("A list splits on every comma, trims spaces and tabs, and drops empty items")
    func listItems() {
        let cases: [(input: String, expected: [String])] = [
            ("a, b ,c", ["a", "b", "c"]),
            ("a,,b", ["a", "b"]),
            ("\ta\t,b", ["a", "b"]),
            (" , ", []),
            ("", []),
            ("'a,b'", ["'a", "b'"]),
            ("a,\nb", ["a", "\nb"]),
            ("NULL", ["NULL"])
        ]
        for testCase in cases {
            #expect(FilterOperand.listItems(testCase.input) == testCase.expected, "\(testCase.input)")
        }
    }

    @Test("An operand keeps its text as typed and reads number and boolean from the trimmed text")
    func operandReadsTrimmedText() {
        let operand = FilterOperand(" 42 ", columnType: Self.integer)

        #expect(operand.text == " 42 ")
        #expect(operand.number == Decimal(42))
        #expect(operand.boolean == nil)
        #expect(!operand.isNullLiteral)

        #expect(FilterOperand(" yes ", columnType: Self.text).boolean == true)
        #expect(FilterOperand("f", columnType: Self.text).boolean == false)
        #expect(FilterOperand("1", columnType: Self.text).boolean == true)
        #expect(FilterOperand("abc", columnType: Self.text).number == nil)
        #expect(FilterOperand("1.50", columnType: nil).number == Decimal(string: "1.5"))
    }

    @Test("NULL is a literal outside text columns, in any case and padding")
    func nullLiteral() {
        let cases: [(raw: String, type: ColumnType?, expected: Bool)] = [
            ("NULL", Self.integer, true),
            (" null ", Self.integer, true),
            ("Null", nil, true),
            ("NULL", Self.text, false),
            ("NULL", .enumType(rawType: "ENUM", values: nil), false),
            ("NULLS", Self.integer, false),
            ("", Self.integer, false)
        ]
        for testCase in cases {
            #expect(
                FilterOperand(testCase.raw, columnType: testCase.type).isNullLiteral == testCase.expected,
                "\(testCase.raw)"
            )
            #expect(
                FilterOperand.readsAsNullLiteral(testCase.raw, columnType: testCase.type) == testCase.expected,
                "\(testCase.raw)"
            )
        }
    }

    @Test("A list compiles each trimmed item into an operand of the column's type")
    func list() {
        let operands = FilterOperand.list(" 1 , NULL,,x", columnType: Self.integer)

        #expect(operands.map(\.text) == ["1", "NULL", "x"])
        #expect(operands.map(\.isNullLiteral) == [false, true, false])
        #expect(operands.map(\.number) == [Decimal(1), nil, nil])
    }
}
