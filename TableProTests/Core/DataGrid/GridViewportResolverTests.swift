//
//  GridViewportResolverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Grid viewport resolver")
struct GridViewportResolverTests {
    private static let keyColumns = ["id"]

    private static func rows(ids: [Int]) -> TableRows {
        TableRows.from(
            queryRows: ids.map { [.text("\($0)"), .text("name-\($0)")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "INTEGER"), .text(rawType: "TEXT")]
        )
    }

    private static func snapshot(
        of tableRows: TableRows,
        firstVisibleRow: Int,
        offset: CGFloat = 0,
        displayIDs: [RowID]? = nil,
        keyColumns: [String] = keyColumns,
        isCellModified: (RowID, Int) -> Bool = { _, _ in false }
    ) -> GridViewportSnapshot {
        GridViewportResolver.snapshot(
            of: tableRows,
            displayIDs: displayIDs,
            firstVisibleDisplayRow: firstVisibleRow,
            firstVisibleOffset: offset,
            keyColumns: keyColumns,
            isCellModified: isCellModified
        )
    }

    private static func placement(
        _ intent: GridReloadIntent,
        from snapshot: GridViewportSnapshot,
        in incoming: TableRows,
        keyColumns: [String] = keyColumns
    ) -> GridViewportPlacement {
        GridViewportResolver.placement(for: intent, from: snapshot, in: incoming, keyColumns: keyColumns)
    }

    @Test("A new view lands on the first row whatever the reader was looking at")
    func firstRowIgnoresThePreviousViewport() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... 100)), firstVisibleRow: 40, offset: 6)

        #expect(Self.placement(.firstRow, from: snapshot, in: Self.rows(ids: Array(1 ... 100))) == .firstRow)
    }

    @Test("Any intent lands on the first row of an empty result")
    func emptyResultLandsOnTheFirstRow() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... 100)), firstVisibleRow: 40)

        #expect(Self.placement(.keepPlace, from: snapshot, in: TableRows()) == .firstRow)
    }

    @Test("Keeping place follows the top row by key when rows arrive above it")
    func keepPlaceFollowsTheTopRowByKey() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array((1 ... 100).reversed())), firstVisibleRow: 40, offset: 7)

        let placement = Self.placement(.keepPlace, from: snapshot, in: Self.rows(ids: Array((1 ... 101).reversed())))

        #expect(placement.firstVisibleRow == .existing(41))
        #expect(placement.firstVisibleOffset == 7)
        #expect(placement.selectedRows.isEmpty)
        #expect(!placement.revealsSelection)
    }

    @Test("A reader at the very top stays there, so a row added above comes into view")
    func keepPlaceAtTheTopStaysAtTheTop() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array((1 ... 100).reversed())), firstVisibleRow: 0)

        let placement = Self.placement(.keepPlace, from: snapshot, in: Self.rows(ids: Array((1 ... 101).reversed())))

        #expect(placement == .firstRow)
    }

    @Test("Keeping place without a key holds the position")
    func keepPlaceWithoutKeysHoldsThePosition() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... 100)), firstVisibleRow: 40, offset: 3, keyColumns: [])

        let placement = Self.placement(.keepPlace, from: snapshot, in: Self.rows(ids: Array(0 ... 100)), keyColumns: [])

        #expect(placement.firstVisibleRow == .existing(40))
        #expect(placement.firstVisibleOffset == 3)
    }

    @Test("Keeping place holds the position when the top row is gone")
    func keepPlaceHoldsThePositionWhenTheTopRowWasDeleted() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... 100)), firstVisibleRow: 40, offset: 5)

        let placement = Self.placement(.keepPlace, from: snapshot, in: Self.rows(ids: Array(1 ... 100).filter { $0 != 41 }))

        #expect(placement.firstVisibleRow == .existing(40))
        #expect(placement.firstVisibleOffset == 5)
    }

    @Test("Keeping place clamps to the last row of a result that shrank")
    func keepPlaceClampsToAShorterResult() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... 100)), firstVisibleRow: 40, offset: 5, keyColumns: [])

        let placement = Self.placement(.keepPlace, from: snapshot, in: Self.rows(ids: Array(1 ... 10)), keyColumns: [])

        #expect(placement.firstVisibleRow == .existing(9))
        #expect(placement.firstVisibleOffset == 0)
    }

    @Test("A key that repeats in the new rows is not an identity, so the position holds")
    func duplicatedKeyFallsBackToPosition() {
        let rows = TableRows.from(
            queryRows: (0 ..< 50).map { [.text("2024-01-05"), .text("\($0)")] },
            columns: ["event_date", "value"],
            columnTypes: [.text(rawType: "Date"), .text(rawType: "Int64")]
        )
        let snapshot = Self.snapshot(of: rows, firstVisibleRow: 30, offset: 2, keyColumns: ["event_date"])

        let placement = Self.placement(.keepPlace, from: snapshot, in: rows, keyColumns: ["event_date"])

        #expect(placement.firstVisibleRow == .existing(30))
        #expect(placement.firstVisibleOffset == 2)
    }

    @Test("A composite key finds its row only when every part matches")
    func compositeKeysMatchEveryColumn() {
        let columns = ["tenant", "id", "name"]
        let types: [ColumnType] = [.text(rawType: "INTEGER"), .text(rawType: "INTEGER"), .text(rawType: "TEXT")]
        let outgoing = TableRows.from(
            queryRows: [[.text("1"), .text("7"), .text("a")], [.text("2"), .text("7"), .text("b")]],
            columns: columns,
            columnTypes: types
        )
        let incoming = TableRows.from(
            queryRows: [
                [.text("1"), .text("8"), .text("new")],
                [.text("1"), .text("7"), .text("a")],
                [.text("2"), .text("7"), .text("b")]
            ],
            columns: columns,
            columnTypes: types
        )
        let snapshot = Self.snapshot(of: outgoing, firstVisibleRow: 1, keyColumns: ["tenant", "id"])

        #expect(Self.placement(.keepPlace, from: snapshot, in: incoming, keyColumns: ["tenant", "id"]).firstVisibleRow == .existing(2))
    }

    @Test("A snapshot reads the top row through the display order of a value filter")
    func snapshotResolvesDisplayPositions() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... 20)), firstVisibleRow: 1, displayIDs: [.existing(4), .existing(9)])

        #expect(snapshot.firstVisibleKey == ["id": "10"])
    }

    @Test("A key with a NULL value is no key, so the position is kept instead")
    func nullKeyFallsBackToPosition() {
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("a")], [.null, .text("b")], [.text("3"), .text("c")]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "INTEGER"), .text(rawType: "TEXT")]
        )
        let snapshot = Self.snapshot(of: rows, firstVisibleRow: 1)

        #expect(snapshot.firstVisibleKey == nil)
        #expect(Self.placement(.keepPlace, from: snapshot, in: rows).firstVisibleRow == .existing(1))
    }

    @Test("An unsaved row is never an anchor, even when its typed key names a saved row")
    func unsavedRowIsNotAnAnchor() {
        var outgoing = Self.rows(ids: Array(1 ... 10))
        _ = outgoing.appendInsertedRow(values: [.text("3"), .text("typed")])

        #expect(Self.snapshot(of: outgoing, firstVisibleRow: 10).firstVisibleKey == nil)
    }

    @Test("A key cell with an unsaved edit is never an anchor")
    func editedKeyIsNotAnAnchor() {
        let snapshot = Self.snapshot(
            of: Self.rows(ids: Array(1 ... 10)),
            firstVisibleRow: 4,
            isCellModified: { rowID, column in rowID == .existing(4) && column == 0 }
        )

        #expect(snapshot.firstVisibleKey == nil)
    }

    @Test("A result above the keyed row limit keeps place by position only")
    func largeResultsKeepPlaceByPosition() {
        let snapshot = Self.snapshot(of: Self.rows(ids: Array(1 ... (GridViewportResolver.keyedRowLimit + 1))), firstVisibleRow: 10)

        #expect(snapshot.firstVisibleKey == nil)
    }

    @Test("Back and Forward select the recorded row and reveal it")
    func restoreRowSelectsTheAnchor() {
        let placement = Self.placement(.restoreRow(["id": "30"]), from: .top, in: Self.rows(ids: Array(1 ... 100)), keyColumns: [])

        #expect(placement.firstVisibleRow == nil)
        #expect(placement.selectedRows == [.existing(29)])
        #expect(placement.revealsSelection)
    }

    @Test("A recorded row that is gone, or no longer unique, lands on the first row")
    func restoreRowNeedsOneMatch() {
        let missing = Self.placement(.restoreRow(["id": "999"]), from: .top, in: Self.rows(ids: Array(1 ... 100)), keyColumns: [])
        let duplicated = Self.placement(.restoreRow(["id": "7"]), from: .top, in: Self.rows(ids: [7, 7, 8]), keyColumns: [])

        #expect(missing == .firstRow)
        #expect(duplicated == .firstRow)
    }
}
