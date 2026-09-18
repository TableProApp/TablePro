//
//  ColumnOrderMergeTests.swift
//  TableProTests
//
//  A captured column order only lists the columns the query returned, so hiding a column takes it
//  out of the capture. Writing the capture over the stored order therefore erased the hidden
//  column's position for good, and Show All appended it at the end of a grid the user had arranged.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column order merge")
struct ColumnOrderMergeTests {
    @Test("A column missing from the capture keeps its stored position")
    func absentColumnKeepsItsSlot() {
        let merged = ColumnLayoutState.mergedColumnOrder(
            current: ["id", "notes", "name", "email"],
            incoming: ["id", "name", "email"]
        )
        #expect(merged == ["id", "notes", "name", "email"])
    }

    @Test("The capture's own order wins for the columns it covers")
    func captureReordersWhatItCovers() {
        let merged = ColumnLayoutState.mergedColumnOrder(
            current: ["id", "notes", "name", "email"],
            incoming: ["email", "id", "name"]
        )
        #expect(merged == ["email", "notes", "id", "name"])
    }

    /// Only a narrowing of the same set is a partial capture. A capture naming a column the stored
    /// order never had describes a different result, so it replaces rather than accumulating names
    /// from a table this layout no longer describes.
    @Test("A capture with a new column replaces the stored order")
    func newColumnReplacesOrder() {
        let merged = ColumnLayoutState.mergedColumnOrder(
            current: ["id", "name"],
            incoming: ["id", "name", "created_at"]
        )
        #expect(merged == ["id", "name", "created_at"])
    }

    @Test("A capture for a different table replaces the stored order outright")
    func differentTableReplacesOrder() {
        let merged = ColumnLayoutState.mergedColumnOrder(
            current: ["id", "name"],
            incoming: ["email"]
        )
        #expect(merged == ["email"])
    }

    @Test("No stored order adopts the capture wholesale")
    func emptyCurrentAdoptsIncoming() {
        #expect(ColumnLayoutState.mergedColumnOrder(current: nil, incoming: ["a", "b"]) == ["a", "b"])
        #expect(ColumnLayoutState.mergedColumnOrder(current: [], incoming: ["a", "b"]) == ["a", "b"])
    }

    @Test("No capture leaves the stored order alone")
    func nilIncomingKeepsCurrent() {
        #expect(ColumnLayoutState.mergedColumnOrder(current: ["a", "b"], incoming: nil) == ["a", "b"])
    }

    /// The reported sequence: arrange the grid, hide a column, then drag another. The capture that
    /// follows the drag omits the hidden column, and before the merge that dropped it permanently.
    @Test("Hiding then reordering does not lose the hidden column's place")
    func hideThenReorderKeepsHiddenColumn() {
        let arranged = ["id", "notes", "name", "email", "created_at"]
        let afterHidingNotesAndDraggingEmail = ["email", "id", "name", "created_at"]

        let merged = ColumnLayoutState.mergedColumnOrder(
            current: arranged,
            incoming: afterHidingNotesAndDraggingEmail
        )

        #expect(merged?.contains("notes") == true)
        #expect(merged?.firstIndex(of: "notes") == 1)
    }

    /// Reset is not a capture. Routing it through the merge made "clear the layout" a no-op, so a
    /// DDL column reorder kept the order from before the change.
    @Test("resetGeometry clears the order the merge would have kept")
    func resetClearsOrder() {
        var stored = ColumnLayoutState()
        stored.columnOrder = ["id", "notes", "name"]
        stored.columnWidths = ["id": 80]

        stored.resetGeometry()

        #expect(stored.columnOrder == nil)
        #expect(stored.columnWidths.isEmpty)
    }

    @Test("applyGeometry merges rather than replacing the order")
    func applyGeometryMerges() {
        var stored = ColumnLayoutState()
        stored.columnOrder = ["id", "notes", "name"]

        var captured = ColumnLayoutState()
        captured.columnOrder = ["name", "id"]

        stored.applyGeometry(from: captured)

        #expect(stored.columnOrder == ["name", "notes", "id"])
    }
}
