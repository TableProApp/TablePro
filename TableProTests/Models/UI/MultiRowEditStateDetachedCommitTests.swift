//
//  MultiRowEditStateDetachedCommitTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct MultiRowEditStateDetachedCommitTests {
    private func makeState(rowIDs: [RowID], values: [[String?]]) -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            selectedRowIndices: Set(rowIDs.indices),
            rowIDs: rowIDs,
            allRows: values,
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        return state
    }

    @Test("a commit while the same rows are selected is an ordinary field edit")
    func commitsThroughTheFieldWhileTheSelectionHolds() {
        let state = makeState(rowIDs: [.existing(1)], values: [["2", "Bob"]])
        var fieldEdits: [(Int, PluginCellValue)] = []
        var detached: [(Int, PluginCellValue, [RowID])] = []
        state.onFieldChanged = { columnIndex, value, _ in fieldEdits.append((columnIndex, value)) }
        state.onDetachedFieldChanged = { detached.append(($0, $1, $2)) }

        state.updateDetachedField(columnIndex: 1, rowIDs: [.existing(1)], value: "Zed")

        #expect(fieldEdits.count == 1)
        #expect(detached.isEmpty)
        #expect(state.fields[1].pendingValue == "Zed")
    }

    /// The field's id is reissued on every selection change, so the lookup this replaced failed and
    /// dropped the text with no warning.
    @Test("a commit after the selection moved writes the rows the window was opened for")
    func commitsToTheOpenedRowsAfterTheSelectionMoved() {
        let state = makeState(rowIDs: [.existing(1)], values: [["2", "Bob"]])
        var detached: [(Int, PluginCellValue, [RowID])] = []
        state.onFieldChanged = { _, _, _ in Issue.record("the field path must not take a moved selection") }
        state.onDetachedFieldChanged = { detached.append(($0, $1, $2)) }

        state.configure(
            selectedRowIndices: [0],
            rowIDs: [.existing(2)],
            allRows: [["3", "Carol"]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        state.updateDetachedField(columnIndex: 1, rowIDs: [.existing(1)], value: "Zed")

        #expect(detached.count == 1)
        #expect(detached.first?.2 == [.existing(1)])
        #expect(detached.first?.1 == .text("Zed"))
        #expect(state.fields[1].pendingValue == nil)
    }

    @Test("a commit naming no rows does nothing")
    func commitWithoutRowsDoesNothing() {
        let state = makeState(rowIDs: [.existing(1)], values: [["2", "Bob"]])
        var detached = 0
        state.onDetachedFieldChanged = { _, _, _ in detached += 1 }

        state.updateDetachedField(columnIndex: 1, rowIDs: [], value: "Zed")

        #expect(detached == 0)
        #expect(state.fields[1].pendingValue == nil)
    }
}
