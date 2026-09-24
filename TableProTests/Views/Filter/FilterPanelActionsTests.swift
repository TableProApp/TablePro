//
//  FilterPanelActionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
private final class RecordingFilterPanelActions: FilterPanelActions {
    private(set) var calls: [String] = []

    func applyAllFilters() { calls.append("applyAll") }
    func applySoloFilter(_ filter: TableFilter) { calls.append("applySolo") }
    func clearAppliedFiltersAndReload() { calls.append("clear") }
    func removeAllFiltersAndReload() { calls.append("removeAll") }
    func closeFilterPanel() { calls.append("close") }
    func focusGrid() { calls.append("focus") }
}

@Suite("Filter panel actions")
@MainActor
struct FilterPanelActionsTests {
    @Test("Removing a row reloads only when it was running, and clears when nothing is left running")
    func reloadAfterRemoving() {
        let remaining = TestFixtures.makeTableFilter(column: "name")
        let cases: [(outcome: TabFilterState.RemoveFilterOutcome, expected: [String])] = [
            (.noChange, []),
            (.clear, ["clear"]),
            (.reapply([remaining]), ["applyAll"])
        ]
        for testCase in cases {
            let actions = RecordingFilterPanelActions()
            actions.reload(after: testCase.outcome)
            #expect(actions.calls == testCase.expected, "\(testCase.outcome)")
        }
    }
}
