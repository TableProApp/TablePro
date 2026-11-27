import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct RowIDRunsTests {
    private func rows(_ ids: [RowID]) -> TableRows {
        TableRows(
            rows: ContiguousArray(ids.map { Row(id: $0, values: [.text("v")]) }),
            columns: ["c"],
            columnTypes: [.text(rawType: nil)]
        )
    }

    @Test("Consecutive existing ids are one run and read back in order")
    func consecutiveIDsAreOneRun() {
        let ids = (10..<1_000).map { RowID.existing($0) }

        let runs = RowIDRuns(ids)

        #expect(runs.runCount == 1)
        #expect(runs.count == ids.count)
        #expect(Array(runs) == ids)
    }

    @Test("A gap, a step back or an inserted row starts a new run and keeps the order")
    func breaksKeepTheOrder() {
        let inserted = RowID.inserted(UUID())
        let ids: [RowID] = [.existing(1), .existing(2), .existing(5), .existing(4), inserted, .existing(6)]

        let runs = RowIDRuns(ids)

        #expect(Array(runs) == ids)
        #expect(runs.count == ids.count)
        #expect(runs.runCount == 5)
    }

    @Test("Runs built from rows equal runs built id by id")
    func rowsBuildTheSameRuns() {
        let inserted = RowID.inserted(UUID())
        let ids: [RowID] = [.existing(0), .existing(1), inserted, .existing(2), .existing(3), .existing(9)]
        let storage = rows(ids)
        var built = RowIDRuns()

        storage.rows.withUnsafeBufferPointer { built.append(rowsIn: $0) }

        #expect(built == RowIDRuns(ids))
        #expect(built.hashValue == RowIDRuns(ids).hashValue)
    }

    @Test("Two ranges that meet join into one run")
    func meetingRangesJoin() {
        let storage = rows((0..<6).map { .existing($0) })

        let runs = DataGridRowOrder.unfiltered.rowIDRuns(atDisplayIndexes: IndexSet([0, 1, 2, 3, 4, 5]), in: storage)

        #expect(runs.runCount == 1)
    }

    @Test("Display indexes resolve to the same ids as the array form, past the end included")
    func matchesTheArrayForm() {
        let storage = rows((0..<8).map { .existing($0 * 2) })
        let indexes = IndexSet([0, 1, 4, 5, 6, 7, 20])
        let unfiltered = DataGridRowOrder.unfiltered
        let filtered = DataGridRowOrder(filteredIDs: [.existing(6), .existing(2), .existing(14)], revision: 1)

        #expect(Array(unfiltered.rowIDRuns(atDisplayIndexes: indexes, in: storage))
            == unfiltered.rowIDs(atDisplayIndexes: indexes, in: storage))
        #expect(Array(filtered.rowIDRuns(atDisplayIndexes: indexes, in: storage))
            == filtered.rowIDs(atDisplayIndexes: indexes, in: storage))
    }

    @Test("A snapshot of a whole result holds one run however many rows it names")
    func snapshotOfEveryRowIsOneRun() {
        let storage = rows((0..<50_000).map { .existing($0) })
        let columns = DataGridColumnSet(tableRows: storage, layout: ColumnLayoutState())
        let selection = GridSelection(
            rectangles: [GridRect(rows: 0...49_999, columns: 0...0)],
            activeCell: GridCoord(row: 0, displayColumn: 0),
            anchor: GridCoord(row: 0, displayColumn: 0),
            mode: .rows
        )

        let snapshot = GridSelectionSnapshot(selection, order: .unfiltered, rows: storage, columns: columns)

        #expect(snapshot.rowRuns.runCount == 1)
        #expect(snapshot.rowRuns.count == 50_000)
        #expect(snapshot.rectangles.first?.rowRuns.runCount == 1)
        #expect(snapshot.resolved(order: .unfiltered, rows: storage, columns: columns).affectedRows == IndexSet(integersIn: 0..<50_000))
    }
}
