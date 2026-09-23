//
//  CellFilterStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A cell's Filter item narrows what the grid shows by one condition, so the next state has to run
/// exactly the rows that were running plus the new one, and has to say so in the panel's checkboxes,
/// which is also what the saved state restores.
@Suite("Cell filter state")
@MainActor
struct CellFilterStateTests {
    private let added = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid")

    private func running(_ filters: [TableFilter], executed: [TableFilter]? = nil) -> TabFilterState {
        var state = TabFilterState()
        state.filters = filters
        state.commit = .all
        state.executedFilters = executed ?? filters.filter { $0.isEnabled && $0.isValid }
        return state
    }

    private func conditions(_ filters: [TableFilter]) -> [String] {
        filters.map { "\($0.columnName) \($0.filterOperator.rawValue) \($0.value)" }
    }

    @Test("With no filters the condition runs alone and the panel opens")
    func noFilters() {
        let next = FilterCoordinator.cellFilterState(TabFilterState(), adding: added)

        #expect(next.filters.map(\.id) == [added.id])
        #expect(next.appliedFilters.map(\.id) == [added.id])
        #expect(next.commit == .all)
        #expect(next.isVisible)
    }

    @Test("A filter already running on another column stays, and both must match")
    func keepsRunningFilterOnAnotherColumn() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")

        let next = FilterCoordinator.cellFilterState(running([country]), adding: added)

        #expect(conditions(next.appliedFilters) == ["country = VN", "status = paid"])
        #expect(next.filterLogicMode == .and)
    }

    @Test("A running filter on the same column is kept, so the result only narrows")
    func keepsRunningFilterOnTheSameColumn() {
        let notCancelled = TestFixtures.makeTableFilter(column: "status", op: .notEqual, value: "cancelled")

        let next = FilterCoordinator.cellFilterState(running([notCancelled]), adding: added)

        #expect(conditions(next.appliedFilters) == ["status != cancelled", "status = paid"])
    }

    @Test("Rows Clear left in the panel are not run again")
    func clearedRowsStayOff() {
        let cleared = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        var state = TabFilterState()
        state.filters = [cleared]
        state.commit = nil
        state.executedFilters = []

        let next = FilterCoordinator.cellFilterState(state, adding: added)

        #expect(next.filters.map(\.id) == [cleared.id, added.id])
        #expect(next.filters.map(\.isEnabled) == [false, true])
        #expect(next.appliedFilters.map(\.id) == [added.id])
    }

    @Test("A row typed and never applied is not run")
    func draftRowStaysOff() {
        let applied = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let draft = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")

        let next = FilterCoordinator.cellFilterState(
            running([applied, draft], executed: [applied]), adding: added
        )

        #expect(conditions(next.appliedFilters) == ["country = VN", "status = paid"])
        #expect(next.filters.first { $0.id == draft.id }?.isEnabled == false)
    }

    @Test("A soloed row stays running even when its checkbox was off")
    func soloedRowStaysRunning() {
        let soloed = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN", isEnabled: false)
        let other = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")
        var state = TabFilterState()
        state.filters = [soloed, other]
        state.commit = .solo(soloed.id)
        state.executedFilters = state.appliedFilters

        let next = FilterCoordinator.cellFilterState(state, adding: added)

        #expect(conditions(next.appliedFilters) == ["country = VN", "status = paid"])
        #expect(next.filters.map(\.isEnabled) == [true, false, true])
    }

    @Test("A running row edited since it ran keeps running with the panel's value")
    func editedRunningRowKeepsRunning() {
        let original = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        var edited = original
        edited.value = "JP"

        let next = FilterCoordinator.cellFilterState(
            running([edited], executed: [original]), adding: added
        )

        #expect(conditions(next.appliedFilters) == ["country = JP", "status = paid"])
    }

    @Test("A row that already holds the condition is checked instead of repeated")
    func reusesAnIdenticalRow() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let sameButOff = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid", isEnabled: false)

        let next = FilterCoordinator.cellFilterState(
            running([country, sameButOff], executed: [country]), adding: added
        )

        #expect(next.filters.map(\.id) == [country.id, sameButOff.id])
        #expect(next.appliedFilters.map(\.id) == [country.id, sameButOff.id])
    }

    @Test("Under Match any with one running row the condition joins it under Match all")
    func matchAnyWithOneRowBecomesMatchAll() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        var state = running([country])
        state.filterLogicMode = .or

        let next = FilterCoordinator.cellFilterState(state, adding: added)

        #expect(conditions(next.appliedFilters) == ["country = VN", "status = paid"])
        #expect(next.filterLogicMode == .and)
    }

    @Test("Under Match any with several running rows the condition runs alone")
    func matchAnyWithSeveralRowsRunsAlone() {
        let vn = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let jp = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "JP")
        var state = running([vn, jp])
        state.filterLogicMode = .or

        let next = FilterCoordinator.cellFilterState(state, adding: added)

        #expect(next.appliedFilters.map(\.id) == [added.id])
        #expect(next.filters.count == 3)
        #expect(next.filterLogicMode == .or)
    }

    @Test("The find bar's search, which never enters the panel, gives way to the condition")
    func crossColumnSearchGivesWay() {
        let search = ["name", "email"].map {
            TestFixtures.makeTableFilter(column: $0, op: .contains, value: "ada")
        }
        var state = TabFilterState()
        state.filterLogicMode = .or
        state.executedFilters = search

        let next = FilterCoordinator.cellFilterState(state, adding: added)

        #expect(next.appliedFilters.map(\.id) == [added.id])
        #expect(next.filterLogicMode == .and)
    }

    @Test("The saved state restores exactly the rows the condition left running")
    func persistedStateRestoresTheSameRows() {
        let cleared = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let next = FilterCoordinator.cellFilterState(
            running([cleared, country], executed: [country]), adding: added
        )

        let restored = FilterCoordinator.resolvedRestoredState(
            settings: FilterSettings(restoreBehavior: .restoreAndApply),
            saved: next.persistedState,
            current: TabFilterState()
        )

        #expect(restored.appliedFilters.map(\.id) == next.appliedFilters.map(\.id))
    }

    @Test("A condition the rows were already fetched with is running")
    func isRunning() {
        let same = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid")
        let other = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")

        #expect(FilterCoordinator.isRunning(added, in: running([same, other])))
        #expect(!FilterCoordinator.isRunning(added, in: running([other])))

        var matchAny = running([same, other])
        matchAny.filterLogicMode = .or
        #expect(!FilterCoordinator.isRunning(added, in: matchAny), "under Match any it widened the rows")

        var editedAway = running([same])
        editedAway.executedFilters = [other]
        #expect(!FilterCoordinator.isRunning(added, in: editedAway), "only what was fetched counts")
    }
}
