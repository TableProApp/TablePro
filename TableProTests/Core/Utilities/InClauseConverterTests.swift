//
//  InClauseConverterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

@testable import TablePro
import Testing

@Suite("IN Clause Converter")
struct InClauseConverterTests {
    private func makeConverter(
        columnIndex: Int,
        columnTypes: [ColumnType],
        escape: ((String) -> String)? = nil
    ) -> InClauseConverter {
        InClauseConverter(columnIndex: columnIndex, columnTypes: columnTypes, escapeStringLiteral: escape)
    }

    @Test("Empty rows yields empty parens")
    func emptyRows() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.integer(rawType: nil)])
        let result = converter.generateInClause(rows: [])
        #expect(result == "()")
    }

    @Test("Integer column produces unquoted values")
    func integers() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.integer(rawType: nil)])
        let result = converter.generateInClause(rows: [["1"], ["2"], ["3"]])
        #expect(result == "(1, 2, 3)")
    }

    @Test("Text column produces quoted values")
    func text() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.text(rawType: nil)])
        let result = converter.generateInClause(rows: [["alice"], ["bob"]])
        #expect(result == "('alice', 'bob')")
    }

    @Test("Single quote in text is escaped by doubling when no driver escape is provided")
    func defaultEscape() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.text(rawType: nil)])
        let result = converter.generateInClause(rows: [["O'Brien"]])
        #expect(result == "('O''Brien')")
    }

    @Test("Driver-provided escape is used when available")
    func driverEscape() {
        let converter = makeConverter(
            columnIndex: 0,
            columnTypes: [.text(rawType: nil)],
            escape: { $0.replacingOccurrences(of: "'", with: "\\'") }
        )
        let result = converter.generateInClause(rows: [["O'Brien"]])
        #expect(result == "('O\\'Brien')")
    }

    @Test("NULL values are excluded so the IN clause matches its non-NULL siblings cleanly")
    func nullExcluded() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.integer(rawType: nil)])
        let result = converter.generateInClause(rows: [["1"], [nil], ["3"]])
        #expect(result == "(1, 3)")
    }

    @Test("All-NULL selection yields empty parens")
    func allNull() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.integer(rawType: nil)])
        let result = converter.generateInClause(rows: [[nil], [nil]])
        #expect(result == "()")
    }

    @Test("Integer column preserves HUGEINT values beyond Int64 range")
    func hugeIntInteger() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.integer(rawType: nil)])
        let max = "170141183460469231731687303715884105727"
        let min = "-170141183460469231731687303715884105728"
        let result = converter.generateInClause(rows: [[PluginCellValue.text(max)], [PluginCellValue.text(min)]])
        #expect(result == "(\(max), \(min))")
    }

    @Test("Boolean true variants normalize to TRUE")
    func boolTrue() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.boolean(rawType: nil)])
        let result = converter.generateInClause(rows: [["true"], ["1"], ["yes"], ["on"]])
        #expect(result == "(TRUE, TRUE, TRUE, TRUE)")
    }

    @Test("Boolean false variants normalize to FALSE")
    func boolFalse() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.boolean(rawType: nil)])
        let result = converter.generateInClause(rows: [["false"], ["0"], ["no"], ["off"]])
        #expect(result == "(FALSE, FALSE, FALSE, FALSE)")
    }

    @Test("Decimal column emits unquoted values")
    func decimals() {
        let converter = makeConverter(columnIndex: 0, columnTypes: [.decimal(rawType: nil)])
        let result = converter.generateInClause(rows: [["3.14"], ["2.71"]])
        #expect(result == "(3.14, 2.71)")
    }

    @Test("Picks the requested column index, not the first")
    func columnIndexHonored() {
        let converter = makeConverter(
            columnIndex: 1,
            columnTypes: [.text(rawType: nil), .integer(rawType: nil)]
        )
        let result = converter.generateInClause(rows: [["alice", "1"], ["bob", "2"]])
        #expect(result == "(1, 2)")
    }
}
