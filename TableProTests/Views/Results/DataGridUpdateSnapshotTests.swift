//
//  DataGridUpdateSnapshotTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("DataGridUpdateSnapshot reload gate")
struct DataGridUpdateSnapshotTests {
    private func makeSnapshot(
        rowDisplayCount: Int = 3,
        columns: [String] = ["name", "type"],
        reloadVersion: Int = 0,
        contentRevision: Int = 0
    ) -> DataGridUpdateSnapshot {
        DataGridUpdateSnapshot(
            rowDisplayCount: rowDisplayCount,
            columnCount: columns.count,
            columns: columns,
            sortedIDsCount: nil,
            valueFilteredIDsCount: nil,
            displayFormats: [],
            configuration: DataGridConfiguration(),
            isEditable: true,
            hasMoveDelegate: false,
            rowHeight: 24,
            alternatingRows: true,
            reloadVersion: reloadVersion,
            contentRevision: contentRevision,
            showObjectComments: false
        )
    }

    @Test("A filter/sort change at the same row count still changes the snapshot")
    func contentRevisionBumpChangesSnapshot() {
        let before = makeSnapshot(rowDisplayCount: 3, contentRevision: 0)
        let after = makeSnapshot(rowDisplayCount: 3, contentRevision: 1)
        #expect(before != after)
    }

    @Test("Nothing changing leaves the snapshot equal so the grid does not reload")
    func identicalSnapshotsAreEqual() {
        let first = makeSnapshot()
        let second = makeSnapshot()
        #expect(first == second)
    }

    @Test("contentRevision is independent of reloadVersion and row count")
    func contentRevisionIsIndependentSignal() {
        let base = makeSnapshot(rowDisplayCount: 5, reloadVersion: 2, contentRevision: 4)
        #expect(base != makeSnapshot(rowDisplayCount: 5, reloadVersion: 2, contentRevision: 5))
        #expect(base != makeSnapshot(rowDisplayCount: 6, reloadVersion: 2, contentRevision: 4))
        #expect(base != makeSnapshot(rowDisplayCount: 5, reloadVersion: 3, contentRevision: 4))
    }
}
