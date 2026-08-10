//
//  HistoryPanelSelectionTests.swift
//  TableProTests
//
//  Tests for the selection that survives deleting a history entry.
//

import Foundation
@testable import TablePro
import Testing

@Suite("HistoryPanel selection after deletion")
struct HistoryPanelSelectionTests {
    @Test("Deleting a middle entry selects the entry that took its place")
    func middleDeletionKeepsPosition() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 1, remainingCount: 3) == 1)
    }

    @Test("Deleting the last entry selects the new last entry")
    func lastDeletionMovesUp() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 3, remainingCount: 3) == 2)
    }

    @Test("Deleting the first entry selects the new first entry")
    func firstDeletionSelectsFirst() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 0, remainingCount: 5) == 0)
    }

    @Test("Deleting the only entry clears the selection")
    func emptyListClearsSelection() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 0, remainingCount: 0) == nil)
    }

    @Test("A negative index clears the selection")
    func negativeIndexClearsSelection() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: -1, remainingCount: 4) == nil)
    }
}
