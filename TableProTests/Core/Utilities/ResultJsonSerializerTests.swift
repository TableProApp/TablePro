//
//  ResultJsonSerializerTests.swift
//  TableProTests
//
//  The JSON results view and the grid's Copy as JSON share one serializer and part company on one
//  thing: pending deletions. Copy as JSON passes none, so it keeps every selected row.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ResultJsonSerializer")
struct ResultJsonSerializerTests {
    private func makeTableRows() -> TableRows {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a")]),
            Row(id: .existing(1), values: [.text("b")]),
            Row(id: .existing(2), values: [.text("c")]),
        ]
        return TableRows(rows: rows, columns: ["name"], columnTypes: [.text(rawType: nil)])
    }

    private func serialize(
        displayIDs: [RowID]? = nil,
        selected: Set<Int> = [],
        deleted: Set<Int>? = nil
    ) -> ResultJsonSerializer.Output {
        guard let deleted else {
            return ResultJsonSerializer.serialize(
                tableRows: makeTableRows(),
                displayIDs: displayIDs,
                selectedDisplayIndices: selected,
                columns: .identity
            )
        }
        return ResultJsonSerializer.serialize(
            tableRows: makeTableRows(),
            displayIDs: displayIDs,
            selectedDisplayIndices: selected,
            deletedDisplayIndices: deleted,
            columns: .identity
        )
    }

    @Test("omitting the deleted set serialises every row, so Copy as JSON is unchanged")
    func omittedDeletedSetKeepsEveryRow() {
        let withoutParameter = serialize(selected: [0, 1])
        let withEmptyParameter = serialize(selected: [0, 1], deleted: [])

        #expect(withoutParameter.rowCount == 2)
        #expect(withoutParameter.json == withEmptyParameter.json)
        #expect(withoutParameter.json.contains("\"b\""))
    }

    @Test("a supplied deleted position is skipped")
    func deletedPositionIsSkipped() {
        let output = serialize(deleted: [1])

        #expect(output.rowCount == 2)
        #expect(output.json.contains("\"a\""))
        #expect(!output.json.contains("\"b\""))
        #expect(output.json.contains("\"c\""))
    }

    @Test("deleted positions are display positions, not storage indices")
    func deletedPositionsAreDisplayPositions() {
        let output = serialize(displayIDs: [.existing(2), .existing(1)], deleted: [0])

        #expect(output.rowCount == 1)
        #expect(output.json.contains("\"b\""))
        #expect(!output.json.contains("\"c\""))
    }

    @Test("deleting every displayed row leaves an empty array")
    func deletingEverythingLeavesAnEmptyArray() {
        let output = serialize(deleted: [0, 1, 2])

        #expect(output.rowCount == 0)
        #expect(output.json == "[]")
    }
}
