//
//  DisplayedResultReaderTests.swift
//  TableProTests
//
//  Reading a result outside the grid gets the same three questions wrong in the same three ways
//  every time: a display position is not a storage index once a value filter is on, hidden and
//  reordered columns are the reader's business too, and a row marked for deletion is in the buffer
//  but not in the result. `ResultJsonSerializer` had these pinned for JSON; they now belong to the
//  reader both it and AppleScript go through.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("DisplayedResultReader")
struct DisplayedResultReaderTests {
    private func makeTableRows() -> TableRows {
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("a"), .text("1")]),
            Row(id: .existing(1), values: [.text("b"), .text("2")]),
            Row(id: .existing(2), values: [.text("c"), .text("3")])
        ]
        return TableRows(
            rows: rows,
            columns: ["name", "count"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
    }

    private func read(
        displayIDs: [RowID]? = nil,
        selected: Set<Int> = [],
        deleted: Set<Int> = [],
        columns: VisibleColumnProjection = .identity
    ) -> DisplayedResultReader.Output {
        DisplayedResultReader.read(
            tableRows: makeTableRows(),
            displayIDs: displayIDs,
            selectedDisplayIndices: selected,
            deletedDisplayIndices: deleted,
            columns: columns
        )
    }

    private func texts(_ output: DisplayedResultReader.Output) -> [[String]] {
        output.rows.map { row in row.map(ScriptResultEncoder.text(of:)) }
    }

    @Test("An empty selection reads every displayed row")
    func emptySelectionReadsEverything() {
        let output = read()

        #expect(output.columns == ["name", "count"])
        #expect(texts(output) == [["a", "1"], ["b", "2"], ["c", "3"]])
        #expect(output.skippedDeletedCount == 0)
    }

    @Test("A selection reads only those rows, in display order")
    func selectionReadsOnlyThoseRows() {
        let output = read(selected: [2, 0])

        #expect(texts(output) == [["a", "1"], ["c", "3"]])
    }

    /// The invariant a per-column value filter breaks: `GridSelectionState.indices` are positions on
    /// screen, and once `displayIDs` reorders or narrows the rows they stop matching array indices.
    @Test("A selected index is a display position, not a storage index")
    func selectionIndicesAreDisplayPositions() {
        let output = read(displayIDs: [.existing(2), .existing(0)], selected: [0])

        #expect(texts(output) == [["c", "3"]])
    }

    @Test("A filtered-out row is not readable at all")
    func filteredRowsAreInvisible() {
        let output = read(displayIDs: [.existing(1)])

        #expect(texts(output) == [["b", "2"]])
    }

    @Test("A row marked for deletion is left out and counted")
    func deletedRowsAreSkipped() {
        let output = read(deleted: [1])

        #expect(texts(output) == [["a", "1"], ["c", "3"]])
        #expect(output.skippedDeletedCount == 1)
    }

    @Test("Hidden and reordered columns follow the grid")
    func columnProjectionIsApplied() {
        let output = read(columns: VisibleColumnProjection(indices: [1]))

        #expect(output.columns == ["count"])
        #expect(texts(output) == [["1"], ["2"], ["3"]])
    }

    @Test("A display position that no longer exists is dropped rather than trapping")
    func outOfRangePositionsAreDropped() {
        let output = read(selected: [0, 99])

        #expect(texts(output) == [["a", "1"]])
    }
}
