//
//  CellFilterStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct CellFilterStateTests {
    private let added = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid")

    private func running(
        _ filters: [TableFilter],
        applied: [TableFilter]? = nil,
        logicMode: FilterLogicMode = .and
    ) -> TabFilterState {
        var state = TabFilterState()
        state.filters = filters
        state.filterLogicMode = logicMode
        state.applied = AppliedFilters(
            filters: applied ?? filters.filter { $0.isEnabled && $0.isValid },
            logicMode: logicMode
        )
        return state
    }

    private func conditions(_ filters: [TableFilter]?) -> [String] {
        (filters ?? []).map { "\($0.columnName) \($0.filterOperator.rawValue) \($0.value)" }
    }

    @Test("With no filters the condition runs alone and the panel opens")
    func noFilters() {
        let next = TabFilterState.cellFilterState(TabFilterState(), adding: added)

        #expect(next.filters.map(\.id) == [added.id])
        #expect(next.applied?.filters.map(\.id) == [added.id])
        #expect(next.status == .applied)
        #expect(next.isVisible)
    }

    @Test("A filter already running on another column stays, and both must match")
    func keepsRunningFilterOnAnotherColumn() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")

        let next = TabFilterState.cellFilterState(running([country]), adding: added)

        #expect(conditions(next.applied?.filters) == ["country = VN", "status = paid"])
        #expect(next.applied?.logicMode == .and)
        #expect(next.filterLogicMode == .and)
    }

    @Test("A running filter on the same column is kept, so the result only narrows")
    func keepsRunningFilterOnTheSameColumn() {
        let notCancelled = TestFixtures.makeTableFilter(column: "status", op: .notEqual, value: "cancelled")

        let next = TabFilterState.cellFilterState(running([notCancelled]), adding: added)

        #expect(conditions(next.applied?.filters) == ["status != cancelled", "status = paid"])
    }

    @Test("Rows Turn Off left in the panel are not run again")
    func turnedOffRowsStayOff() {
        let left = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let state = running([left]).turningOff()

        let next = TabFilterState.cellFilterState(state, adding: added)

        #expect(next.filters.map(\.id) == [left.id, added.id])
        #expect(next.filters.map(\.isEnabled) == [false, true])
        #expect(next.applied?.filters.map(\.id) == [added.id])
    }

    @Test("A row typed and never applied is not run")
    func draftRowStaysOff() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let draft = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")

        let next = TabFilterState.cellFilterState(
            running([country, draft], applied: [country]), adding: added
        )

        #expect(conditions(next.applied?.filters) == ["country = VN", "status = paid"])
        #expect(next.filters.first { $0.id == draft.id }?.isEnabled == false)
    }

    @Test("A row applied alone stays running even when its checkbox was off")
    func aloneRowStaysRunning() throws {
        let alone = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN", isEnabled: false)
        let other = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")
        var state = TabFilterState()
        state.filters = [alone, other]
        state = try #require(state.applyingAlone(alone.id))

        let next = TabFilterState.cellFilterState(state, adding: added)

        #expect(conditions(next.applied?.filters) == ["country = VN", "status = paid"])
        #expect(next.filters.map(\.isEnabled) == [true, false, true])
        #expect(next.aloneFilterID == nil)
    }

    @Test("A row applied alone under Match any keeps running and the condition joins it under Match all")
    func aloneRowUnderMatchAnyJoinsUnderMatchAll() throws {
        let vn = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let jp = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "JP")
        var state = TabFilterState()
        state.filters = [vn, jp]
        state.filterLogicMode = .or
        state = try #require(state.applyingAlone(jp.id))

        let next = TabFilterState.cellFilterState(state, adding: added)

        #expect(conditions(next.applied?.filters) == ["country = JP", "status = paid"])
        #expect(next.applied?.logicMode == .and)
        #expect(next.filterLogicMode == .and)
        #expect(next.filters.map(\.isEnabled) == [false, true, true])
    }

    @Test("A running row edited since it ran keeps running with the panel's value")
    func editedRunningRowKeepsRunning() {
        let original = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        var edited = original
        edited.value = "JP"

        let next = TabFilterState.cellFilterState(
            running([edited], applied: [original]), adding: added
        )

        #expect(conditions(next.applied?.filters) == ["country = JP", "status = paid"])
    }

    @Test("A row that already holds the condition is checked instead of repeated")
    func reusesAnIdenticalRow() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let sameButOff = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid", isEnabled: false)

        let next = TabFilterState.cellFilterState(
            running([country, sameButOff], applied: [country]), adding: added
        )

        #expect(next.filters.map(\.id) == [country.id, sameButOff.id])
        #expect(next.applied?.filters.map(\.id) == [country.id, sameButOff.id])
    }

    @Test("Under Match any with one running row the condition joins it under Match all")
    func matchAnyWithOneRowBecomesMatchAll() {
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")

        let next = TabFilterState.cellFilterState(running([country], logicMode: .or), adding: added)

        #expect(conditions(next.applied?.filters) == ["country = VN", "status = paid"])
        #expect(next.applied?.logicMode == .and)
        #expect(next.filterLogicMode == .and)
    }

    @Test("Under Match any with several running rows the condition runs alone")
    func matchAnyWithSeveralRowsRunsAlone() {
        let vn = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let jp = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "JP")

        let next = TabFilterState.cellFilterState(running([vn, jp], logicMode: .or), adding: added)

        #expect(next.applied?.filters.map(\.id) == [added.id])
        #expect(next.filters.count == 3)
        #expect(next.filterLogicMode == .or)
    }

    @Test("What ran decides the mode, not a mode changed in the panel since")
    func appliedLogicModeDecides() {
        let vn = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let total = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")
        var state = running([vn, total])
        state.filterLogicMode = .or

        let next = TabFilterState.cellFilterState(state, adding: added)

        #expect(conditions(next.applied?.filters) == ["country = VN", "total > 5", "status = paid"])
        #expect(next.applied?.logicMode == .and)
    }

    @Test("Search All Rows lives in the panel, so a cell condition runs alone and leaves its rows unchecked")
    func searchAllRowsGivesWay() {
        let state = TabFilterState().searchingAllRows(term: "ada", columns: ["name", "email"])
        let searchIDs = state.filters.map(\.id)

        let next = TabFilterState.cellFilterState(state, adding: added)

        #expect(next.applied?.filters.map(\.id) == [added.id])
        #expect(next.filters.map(\.id) == searchIDs + [added.id])
        #expect(next.filters.map(\.isEnabled) == [false, false, true])
        #expect(next.filterLogicMode == .or)
    }

    @Test("The saved state restores exactly the rows the condition left running")
    func persistedStateRestoresTheSameRows() {
        let left = TestFixtures.makeTableFilter(column: "total", op: .greaterThan, value: "5")
        let country = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")
        let next = TabFilterState.cellFilterState(
            running([left, country], applied: [country]), adding: added
        )

        let restored = FilterCoordinator.resolvedRestoredState(
            settings: FilterSettings(restoreBehavior: .restoreAndApply),
            saved: next.persistedState,
            current: TabFilterState()
        )

        #expect(restored.applied != nil)
        #expect(restored.applied == next.applied)
    }

    @Test("A condition the rows were already fetched with is running")
    func isRunning() {
        let same = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid")
        let other = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")

        #expect(TabFilterState.isRunning(added, in: running([same, other])))
        #expect(!TabFilterState.isRunning(added, in: running([other])))
        #expect(
            !TabFilterState.isRunning(added, in: running([same, other], logicMode: .or)),
            "under Match any it widened the rows"
        )
        #expect(
            !TabFilterState.isRunning(added, in: running([same], applied: [other])),
            "only what was fetched counts"
        )
        #expect(!TabFilterState.isRunning(added, in: running([same]).turningOff()))
    }

    @Test("Whether a condition runs follows the mode it ran with, not the panel's")
    func isRunningReadsAppliedLogicMode() {
        let same = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "paid")
        let other = TestFixtures.makeTableFilter(column: "country", op: .equal, value: "VN")

        var ranUnderMatchAll = running([same, other])
        ranUnderMatchAll.filterLogicMode = .or
        var ranUnderMatchAny = running([same, other], logicMode: .or)
        ranUnderMatchAny.filterLogicMode = .and

        #expect(TabFilterState.isRunning(added, in: ranUnderMatchAll))
        #expect(!TabFilterState.isRunning(added, in: ranUnderMatchAny))
    }

    @Test("A row switched from Raw SQL to a column counts as running when its condition is")
    func switchedRawRowIsRunning() {
        let switched = TableFilter.rawCondition("paid")
            .selectingColumn("status")

        let state = running([switched])

        #expect(TabFilterState.isRunning(added, in: state))
        let next = TabFilterState.cellFilterState(state, adding: added)
        #expect(next.filters.map(\.id) == [switched.id], "no second row for the same condition")
    }
}
