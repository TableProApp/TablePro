//
//  HighlightRuleSetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Highlight rule set")
struct HighlightRuleSetTests {
    private let columns = ["id", "status", "total"]
    private let types: [ColumnType] = [.integer(rawType: "INT"), .text(rawType: "VARCHAR"), .decimal(rawType: "DECIMAL")]

    private func row(_ values: PluginCellValue...) -> ContiguousArray<PluginCellValue> {
        ContiguousArray(values)
    }

    @Test("The first matching row rule sets the row's color, and reordering flips it")
    func firstRowRuleWins() {
        let paid = HighlightRule(columnName: "status", value: "paid", color: .green)
        let big = HighlightRule(columnName: "total", filterOperator: .greaterThan, value: "100", color: .red)
        let values = row("1", "paid", "500")

        let paidFirst = HighlightRuleSet(rules: [paid, big], columns: columns, columnTypes: types)
        let bigFirst = HighlightRuleSet(rules: [big, paid], columns: columns, columnTypes: types)

        #expect(paidFirst.highlight(for: values).rowColor == .green)
        #expect(bigFirst.highlight(for: values).rowColor == .red)
    }

    @Test("A cell rule colours its own column and leaves the row rule in place")
    func cellRulesColourTheirColumn() {
        let rowRule = HighlightRule(columnName: "status", value: "paid", color: .green)
        let cellRule = HighlightRule(
            columnName: "total", filterOperator: .greaterThan, value: "100", color: .red, target: .cell
        )
        let highlight = HighlightRuleSet(rules: [rowRule, cellRule], columns: columns, columnTypes: types)
            .highlight(for: row("1", "paid", "500"))

        #expect(highlight.rowColor == .green)
        #expect(highlight.cellRule(forColumn: 2)?.color == .red)
        #expect(highlight.cellRule(forColumn: 1) == nil)
        #expect(highlight.describingRule(forColumn: 2) == cellRule)
        #expect(highlight.describingRule(forColumn: 0) == rowRule)
    }

    @Test("Disabled and incomplete rules never match")
    func disabledAndIncompleteRules() {
        let disabled = HighlightRule(isEnabled: false, columnName: "status", value: "paid", color: .green)
        let incomplete = HighlightRule(columnName: "status", value: "", color: .red)
        let set = HighlightRuleSet(rules: [disabled, incomplete], columns: columns, columnTypes: types)

        #expect(set.isEmpty)
        #expect(set.highlight(for: row("1", "paid", "5")) == .none)
    }

    @Test("A rule whose column is not in the result is reported, not dropped")
    func missingColumnIsUnresolved() {
        let rule = HighlightRule(columnName: "archived", filterOperator: .isNotNull, color: .gray)
        let set = HighlightRuleSet(rules: [rule], columns: columns, columnTypes: types)

        #expect(set.unresolvedRuleIDs == [rule.id])
        #expect(set.highlight(for: row("1", "paid", "5")) == .none)
    }

    @Test("A duplicated column name resolves by occurrence")
    func duplicateColumnsResolveByOccurrence() {
        let duplicated = ["status", "status"]
        let textTypes: [ColumnType] = [.text(rawType: nil), .text(rawType: nil)]
        let second = HighlightRule(
            columnName: "status", columnOccurrence: 1, value: "paid", color: .blue, target: .cell
        )
        let highlight = HighlightRuleSet(rules: [second], columns: duplicated, columnTypes: textTypes)
            .highlight(for: row("paid", "paid"))

        #expect(highlight.cellRule(forColumn: 0) == nil)
        #expect(highlight.cellRule(forColumn: 1)?.color == .blue)
        #expect(HighlightRuleSet.occurrence(ofColumnAt: 1, in: duplicated) == 1)
        #expect(HighlightRuleSet.columnIndex(named: "status", occurrence: 2, in: duplicated) == nil)
    }
}

@Suite("Highlight rule descriptions and quick rules")
@MainActor
struct HighlightRuleDescriptionTests {
    @Test("A comparison reads as column, symbol and quoted value")
    func comparisonTitle() {
        let rule = HighlightRule(columnName: "status", value: "paid")
        #expect(HighlightRuleDescription.condition(of: rule) == "status = “paid”")
    }

    @Test("An operator without a value reads as its name")
    func valuelessTitle() {
        let rule = HighlightRule(columnName: "notes", filterOperator: .isNull)
        #expect(HighlightRuleDescription.condition(of: rule) == "notes is NULL")
    }

    @Test("A long value is truncated in menu titles only")
    func longValuesTruncate() {
        let value = String(repeating: "x", count: 50)
        let rule = HighlightRule(columnName: "notes", value: value)
        let title = HighlightRuleDescription.condition(of: rule, valueLimit: HighlightRuleDescription.menuValueLimit)

        #expect(title == "notes = “\(String(repeating: "x", count: 32))…”")
        #expect(HighlightRuleDescription.condition(of: rule).contains(value))
    }

    @Test("The quick rule follows the clicked cell's raw value")
    func quickRuleFromCell() {
        let text = HighlightMenuBuilder.quickRule(
            columnName: "status", columnOccurrence: 0, columnType: .text(rawType: "VARCHAR"), value: "paid", target: .row, color: .green
        )
        let null = HighlightMenuBuilder.quickRule(
            columnName: "status", columnOccurrence: 0, columnType: .text(rawType: "VARCHAR"), value: .null, target: .cell, color: .red
        )
        let empty = HighlightMenuBuilder.quickRule(
            columnName: "status", columnOccurrence: 0, columnType: .text(rawType: "VARCHAR"), value: "", target: .row, color: .red
        )
        let binary = HighlightMenuBuilder.quickRule(
            columnName: "blob", columnOccurrence: 0, columnType: .text(rawType: "VARCHAR"), value: .bytes(Data([1])), target: .row, color: .red
        )

        #expect(text?.filterOperator == .equal)
        #expect(text?.value == "paid")
        #expect(null?.filterOperator == .isNull)
        #expect(null?.target == .cell)
        #expect(empty?.filterOperator == .isEmpty)
        #expect(binary == nil)
    }

    @Test("A quick rule cannot be built from a value the rule would read as NULL")
    func quickRuleRefusesTheNullKeyword() {
        let json = HighlightMenuBuilder.quickRule(
            columnName: "payload", columnOccurrence: 0, columnType: .json(rawType: "JSONB"),
            value: "null", target: .row, color: .red
        )
        let text = HighlightMenuBuilder.quickRule(
            columnName: "note", columnOccurrence: 0, columnType: .text(rawType: "VARCHAR"),
            value: "null", target: .row, color: .red
        )

        #expect(json == nil)
        #expect(text?.value == "null")
    }

    @Test("Menu sections name the target and the condition")
    func sectionTitles() {
        let row = HighlightRule(columnName: "status", value: "paid", target: .row)
        let cell = HighlightRule(columnName: "status", value: "paid", target: .cell)

        #expect(HighlightMenuBuilder.sectionTitle(for: row) == "Rows Where status = “paid”")
        #expect(HighlightMenuBuilder.sectionTitle(for: cell) == "Cells Where status = “paid”")
    }

    @Test("Two rules share a condition regardless of their color")
    func sameCondition() {
        let green = HighlightRule(columnName: "status", value: "paid", color: .green)
        var red = green
        red.color = .red
        let cell = HighlightRule(columnName: "status", value: "paid", color: .green, target: .cell)

        #expect(HighlightRule(columnName: "status", value: "paid", color: .red).hasSameCondition(as: green))
        #expect(red.hasSameCondition(as: green))
        #expect(!cell.hasSameCondition(as: green))
    }

    @Test("Duplicated columns get a numbered label")
    func columnOptions() {
        let options = HighlightColumnOption.options(for: ["id", "status", "status"])

        #expect(options.map(\.label) == ["id", "status (1)", "status (2)"])
        #expect(options.map(\.occurrence) == [0, 0, 1])
    }
}
