import Foundation
@testable import TablePro
import Testing

@Suite("RowSelectionSyncDecision")
struct RowSelectionSyncDecisionTests {
    @Test("row binding is written for a changed selection even during a programmatic mouse selection")
    func writesBindingDuringProgrammaticSelection() {
        #expect(RowSelectionSyncDecision.shouldWriteRowBinding(previous: [3], new: [7]))
    }

    @Test("row binding is written when selection changes from keyboard navigation")
    func writesBindingOnChange() {
        #expect(RowSelectionSyncDecision.shouldWriteRowBinding(previous: [], new: [0]))
        #expect(RowSelectionSyncDecision.shouldWriteRowBinding(previous: [2], new: []))
    }

    @Test("row binding is not written when the selection is unchanged")
    func skipsBindingWhenUnchanged() {
        #expect(!RowSelectionSyncDecision.shouldWriteRowBinding(previous: [4], new: [4]))
        #expect(!RowSelectionSyncDecision.shouldWriteRowBinding(previous: [], new: []))
    }

    @Test("cell selection clears on keyboard row navigation that lands on a new row")
    func clearsCellSelectionOnKeyboardNavigation() {
        #expect(RowSelectionSyncDecision.shouldClearCellSelection(
            isProgrammatic: false,
            newSelection: [5],
            cellSelectionEmpty: false
        ))
    }

    @Test("cell selection is preserved during a programmatic row selection")
    func preservesCellSelectionWhenProgrammatic() {
        #expect(!RowSelectionSyncDecision.shouldClearCellSelection(
            isProgrammatic: true,
            newSelection: [5],
            cellSelectionEmpty: false
        ))
    }

    @Test("cell selection is left alone when there is no cell selection or no row selection")
    func skipsClearWhenNothingToClear() {
        #expect(!RowSelectionSyncDecision.shouldClearCellSelection(
            isProgrammatic: false,
            newSelection: [5],
            cellSelectionEmpty: true
        ))
        #expect(!RowSelectionSyncDecision.shouldClearCellSelection(
            isProgrammatic: false,
            newSelection: [],
            cellSelectionEmpty: false
        ))
    }
}
