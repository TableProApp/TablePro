//
//  ComparisonGridCopyTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct ComparisonGridCopyTests {
        private func copyFirstRow(through delegate: any DataGridViewDelegate, rows: TableRows) {
            let coordinator = TableViewCoordinator(
                changeManager: AnyChangeManager(DataChangeManager()),
                isEditable: false,
                selectedRowIndices: .constant([0]),
                delegate: delegate,
                layoutPersister: InMemoryColumnLayoutStore()
            )
            coordinator.tableRowsProvider = { rows }
            coordinator.rebuildColumnMetadataCache(from: rows)
            coordinator.updateCache()
            delegate.dataGridAttach(tableViewCoordinator: coordinator)

            coordinator.copyRows(at: [0], as: .rows)
        }

        @Test("Copying a result comparison row puts the line on the clipboard")
        func resultComparisonCopiesRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let side = ResultComparisonSide(
                title: "Result",
                detail: "Query",
                columns: ["id"],
                rows: [Row(id: .existing(0), values: [.text("7")])]
            )
            let pairing = ResultColumnPairing(left: side.columns, right: side.columns)
            let lines = ResultComparisonGridModel.lines(for: [ResultComparisonEntry(kind: .onlyLeft, leftRow: 0, rightRow: nil)])
            let rows = ResultComparisonGridModel.tableRows(for: lines, left: side, right: side, pairing: pairing)

            copyFirstRow(through: ResultComparisonGridModel(), rows: rows)

            #expect(clipboard.text == "Only Left\tLeft\t7")
        }

        @Test("Copying a Compare & Sync row puts the line on the clipboard")
        func compareSyncCopiesRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let rows = TableRows.from(
                queryRows: [[.text("Insert"), .text("Source"), .text("7")]],
                columns: ["Change", "Side", "id"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .integer(rawType: nil)]
            )

            copyFirstRow(through: CompareRowGridModel(), rows: rows)

            #expect(clipboard.text == "Insert\tSource\t7")
        }
    }
}
