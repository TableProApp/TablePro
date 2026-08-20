//
//  ResultsJsonViewTests.swift
//  TableProTests
//
//  The JSON results view renders the whole result set when nothing is selected, and
//  narrows to the selected rows otherwise. Selection indices are display positions, so
//  they are resolved through DisplayRowMapping rather than used to subscript the rows.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ResultsJsonView")
struct ResultsJsonViewTests {
    private func makeTableRows() -> TableRows {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("active"), .text("a")]),
            Row(id: .existing(1), values: [.text("inactive"), .text("b")]),
            Row(id: .existing(2), values: [.text("active"), .text("c")]),
            Row(id: .existing(3), values: [.null, .text("d")]),
        ]
        return TableRows(
            rows: rows,
            columns: ["status", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
    }

    private func compute(
        displayIDs: [RowID]? = nil,
        selectedIndices: Set<Int>,
        deletedIndices: Set<Int> = [],
        columnLayout: ColumnLayoutState = ColumnLayoutState()
    ) -> ResultsJsonView.RenderedJson {
        ResultsJsonView.computeJson(
            tableRows: makeTableRows(),
            displayIDs: displayIDs,
            selectedIndices: selectedIndices,
            deletedIndices: deletedIndices,
            columnLayout: columnLayout
        )
    }

    @Test("no selection renders every row")
    func noSelectionRendersEveryRow() {
        let result = compute(selectedIndices: [])

        #expect(result.resolvedCount == 4)
        #expect(result.json.contains("\"a\""))
        #expect(result.json.contains("\"d\""))
    }

    @Test("no selection follows the displayed order, not the fetch order")
    func noSelectionFollowsDisplayOrder() {
        let result = compute(displayIDs: [.existing(2), .existing(0)], selectedIndices: [])

        #expect(result.resolvedCount == 2)
        let first = result.json.range(of: "\"c\"")
        let second = result.json.range(of: "\"a\"")
        #expect(first != nil)
        #expect(second != nil)
        if let first, let second {
            #expect(first.lowerBound < second.lowerBound)
        }
    }

    @Test("no selection excludes rows a value filter removed")
    func noSelectionExcludesFilteredRows() {
        let result = compute(displayIDs: [.existing(0), .existing(2)], selectedIndices: [])

        #expect(result.resolvedCount == 2)
        #expect(!result.json.contains("\"b\""))
        #expect(!result.json.contains("\"d\""))
    }

    @Test("a row marked for deletion is left out of the document")
    func pendingDeletionIsExcluded() {
        let result = compute(selectedIndices: [], deletedIndices: [1])

        #expect(result.resolvedCount == 3)
        #expect(!result.json.contains("\"b\""))
        #expect(result.json.contains("\"a\""))
        #expect(result.json.contains("\"d\""))
    }

    @Test("a row marked for deletion is left out even when it is part of the selection")
    func pendingDeletionIsExcludedFromASelection() {
        let result = compute(selectedIndices: [0, 1], deletedIndices: [1])

        #expect(result.resolvedCount == 1)
        #expect(result.json.contains("\"a\""))
        #expect(!result.json.contains("\"b\""))
    }

    @Test("deletion positions are display positions, resolved through the display order")
    func pendingDeletionUsesDisplayPositions() {
        let result = compute(displayIDs: [.existing(2), .existing(0)], selectedIndices: [], deletedIndices: [0])

        #expect(result.resolvedCount == 1)
        #expect(result.json.contains("\"a\""))
        #expect(!result.json.contains("\"c\""))
    }

    @Test("a hidden column is left out")
    func hiddenColumnIsExcluded() {
        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["status"]

        let result = compute(selectedIndices: [], columnLayout: layout)

        #expect(!result.json.contains("status"))
        #expect(result.json.contains("name"))
    }

    @Test("columns follow the order the user arranged")
    func columnsFollowUserOrder() {
        var layout = ColumnLayoutState()
        layout.columnOrder = ["name", "status"]

        let result = compute(selectedIndices: [], columnLayout: layout)

        let name = result.json.range(of: "name")
        let status = result.json.range(of: "status")
        #expect(name != nil)
        #expect(status != nil)
        if let name, let status {
            #expect(name.lowerBound < status.lowerBound)
        }
    }

    @Test("an empty result renders an empty array")
    func emptyResultRendersEmptyArray() {
        let result = ResultsJsonView.computeJson(
            tableRows: TableRows(),
            displayIDs: nil,
            selectedIndices: [],
            columnLayout: ColumnLayoutState()
        )

        #expect(result.resolvedCount == 0)
        #expect(result.json == "[]")
    }

    @Test("wide integers stay exact in JSON text and tree output")
    func wideIntegersStayExact() throws {
        let value = "340282366920938463463374607431768211455"
        let tableRows = TableRows(
            rows: [Row(id: .existing(0), values: [.text(value)])],
            columns: ["value"],
            columnTypes: [.integer(rawType: "UINT128")]
        )

        let result = ResultsJsonView.computeJson(
            tableRows: tableRows,
            displayIDs: nil,
            selectedIndices: [],
            columnLayout: ColumnLayoutState()
        )

        #expect(result.json.contains("\"value\": \(value)"))
        let reindented = try #require(result.json.prettyPrintedAsJson())
        #expect(result.pretty == reindented)
        #expect(reindented.contains(value))
        guard case .success(let root) = result.parseResult else {
            if case .failure(let error) = result.parseResult {
                Issue.record("expected valid JSON tree, got \(error)")
            }
            return
        }
        guard let numberNode = root.children.first?.children.first else {
            Issue.record("expected the wide integer node")
            return
        }
        if case .number = numberNode.valueType {} else {
            Issue.record("expected a JSON number node")
        }
        #expect(numberNode.rawValue == value)
        #expect(numberNode.displayValue == value)
    }

    @Test("a selection narrows the output to the selected rows")
    func selectionNarrowsTheOutput() {
        let result = compute(selectedIndices: [1])

        #expect(result.resolvedCount == 1)
        #expect(result.json.contains("\"b\""))
        #expect(!result.json.contains("\"a\""))
    }

    @Test("a selection resolves through the display order, not the raw row order")
    func selectionResolvesThroughDisplayOrder() {
        let result = compute(displayIDs: [.existing(0), .existing(2)], selectedIndices: [1])

        #expect(result.resolvedCount == 1)
        #expect(result.json.contains("\"c\""))
        #expect(!result.json.contains("\"b\""))
    }

    @Test("a display index past the filtered set is skipped instead of subscripting the rows")
    func outOfRangeDisplayIndexIsSkipped() {
        let result = compute(displayIDs: [.existing(0), .existing(2)], selectedIndices: [1, 7])

        #expect(result.resolvedCount == 1)
        #expect(result.json.contains("\"c\""))
    }

    @Test("a selection that resolves to nothing reports zero rows rather than a full result set")
    func selectionResolvingToNothingReportsZero() {
        let result = compute(selectedIndices: [9, 10])

        #expect(result.resolvedCount == 0)
        #expect(result.json == "[]")
    }

    @Test("selected rows are emitted in display order regardless of selection order")
    func selectedRowsKeepDisplayOrder() {
        let result = compute(selectedIndices: [2, 0])

        #expect(result.resolvedCount == 2)
        let first = result.json.range(of: "\"a\"")
        let second = result.json.range(of: "\"c\"")
        #expect(first != nil)
        #expect(second != nil)
        if let first, let second {
            #expect(first.lowerBound < second.lowerBound)
        }
    }
}
