//
//  TabFilterStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TabFilterStateTests {
    private func draft(_ filters: [TableFilter], logicMode: FilterLogicMode = .and) -> TabFilterState {
        var state = TabFilterState()
        state.filters = filters
        state.filterLogicMode = logicMode
        return state
    }

    private func roundTrip(_ persisted: PersistedFilterState) throws -> PersistedFilterState {
        try JSONDecoder().decode(PersistedFilterState.self, from: JSONEncoder().encode(persisted))
    }

    @Test("Nothing runs until a row is applied")
    func nothingAppliedByDefault() {
        let state = draft([TestFixtures.makeTableFilter(column: "id")])
        #expect(state.applied == nil)
        #expect(!state.isFiltering)
    }

    @Test("Applying checked rows excludes disabled and invalid filters")
    func applyingCheckedRowsExcludesDisabledAndInvalid() {
        let active = TestFixtures.makeTableFilter(column: "id", value: "1")
        let disabled = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        let invalid = TestFixtures.makeTableFilter(column: "", value: "")
        let state = draft([active, disabled, invalid]).applyingCheckedRows()
        #expect(state.applied?.filters == [active])
        #expect(state.applied?.aloneFilterID == nil)
    }

    @Test("A row applied alone runs by itself even with its checkbox off, and every checkbox stays as it was")
    func applyingAloneForcesTheRowOn() throws {
        let other = TestFixtures.makeTableFilter(column: "id", value: "1")
        let target = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        let state = try #require(draft([other, target]).applyingAlone(target.id))
        #expect(state.applied?.filters.map(\.id) == [target.id])
        #expect(state.applied?.filters.first?.isEnabled == true)
        #expect(state.aloneFilterID == target.id)
        #expect(state.filters == [other, target])
    }

    @Test("Applying alone a row the draft does not hold gives nil")
    func applyingAloneMissingRowIsNil() {
        let state = draft([TestFixtures.makeTableFilter(column: "id")])
        #expect(state.applyingAlone(UUID()) == nil)
    }

    @Test("Applying an invalid row alone gives nil")
    func applyingAloneInvalidRowIsNil() {
        let invalid = TestFixtures.makeTableFilter(column: "name", value: "")
        let state = draft([TestFixtures.makeTableFilter(column: "id"), invalid])
        #expect(state.applyingAlone(invalid.id) == nil)
    }

    @Test("What is applied is a snapshot: editing or removing draft rows leaves it as it ran")
    func appliedIsASnapshotOfTheDraft() {
        let first = TestFixtures.makeTableFilter(column: "id", value: "1")
        let second = TestFixtures.makeTableFilter(column: "name", value: "a")
        var state = draft([first, second]).applyingCheckedRows()
        #expect(state.applied?.filters == [first, second])

        state.filters.removeAll { $0.id == second.id }
        state.filters[0].value = "2"
        #expect(state.applied?.filters == [first, second])
    }

    @Test("status is empty when no row could run")
    func statusEmpty() {
        #expect(TabFilterState().status == .empty)

        let state = draft([
            TestFixtures.makeTableFilter(column: "id", isEnabled: false),
            TestFixtures.makeTableFilter(column: "", value: "")
        ])
        #expect(state.status == .empty)
    }

    @Test("status is not applied when a checked row could run and nothing runs")
    func statusNotApplied() {
        let state = draft([TestFixtures.makeTableFilter(column: "id")])
        #expect(state.status == .notApplied)
        #expect(state.applyingCheckedRows().turningOff().status == .notApplied)
    }

    @Test("status is applied when the checked rows run as drafted")
    func statusApplied() {
        let state = draft([TestFixtures.makeTableFilter(column: "id")]).applyingCheckedRows()
        #expect(state.status == .applied)
    }

    @Test("status is applied alone when one row runs on its own")
    func statusAppliedAlone() throws {
        let row = TestFixtures.makeTableFilter(column: "id")
        let state = try #require(draft([row, TestFixtures.makeTableFilter(column: "name")]).applyingAlone(row.id))
        #expect(state.status == .appliedAlone)
    }

    @Test("status is changes not applied when the draft differs from what runs")
    func statusChangesNotApplied() {
        var state = draft([TestFixtures.makeTableFilter(column: "id", value: "1")]).applyingCheckedRows()
        state.filters[0].value = "2"
        #expect(state.status == .changesNotApplied)
    }

    @Test("A value edit after Apply is an unapplied change")
    func valueEditIsUnapplied() {
        var state = draft([TestFixtures.makeTableFilter(column: "id", value: "1")])
        #expect(!state.hasUnappliedChanges)

        state = state.applyingCheckedRows()
        #expect(!state.hasUnappliedChanges)

        state.filters[0].value = "2"
        #expect(state.hasUnappliedChanges)
    }

    @Test("A logic mode change is unapplied with two or more running rows, not with one")
    func logicModeChangeNeedsTwoRows() {
        var two = draft([
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name")
        ]).applyingCheckedRows()
        two.filterLogicMode = .or
        #expect(two.hasUnappliedChanges)

        var one = draft([
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        ]).applyingCheckedRows()
        one.filterLogicMode = .or
        #expect(!one.hasUnappliedChanges)
    }

    @Test("Reordering running rows is not an unapplied change")
    func reorderIsNotUnapplied() {
        let first = TestFixtures.makeTableFilter(column: "id")
        var state = draft([first, TestFixtures.makeTableFilter(column: "name")]).applyingCheckedRows()

        state.moveFilter(first.id, direction: .down)

        #expect(state.filters.last?.id == first.id)
        #expect(!state.hasUnappliedChanges)
    }

    @Test("Unchecking a running row is an unapplied change")
    func uncheckingRunningRowIsUnapplied() {
        var state = draft([
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name")
        ]).applyingCheckedRows()

        state.filters[1].isEnabled = false

        #expect(state.hasUnappliedChanges)
    }

    @Test("Editing another row while one runs alone is not an unapplied change")
    func editingOtherRowWhileAloneIsNotUnapplied() throws {
        let alone = TestFixtures.makeTableFilter(column: "id")
        var state = try #require(
            draft([alone, TestFixtures.makeTableFilter(column: "name", value: "a")]).applyingAlone(alone.id)
        )

        state.filters[1].value = "b"
        state.filters[1].isEnabled = false

        #expect(!state.hasUnappliedChanges)
        #expect(state.status == .appliedAlone)
    }

    @Test("persistedState keeps every valid row with its own enabled flag, whatever was applied")
    func persistedStateKeepsWorkingSetForEveryApplication() throws {
        let checked = TestFixtures.makeTableFilter(column: "id", value: "1")
        let unchecked = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        let invalid = TestFixtures.makeTableFilter(column: "", value: "")
        let state = draft([checked, unchecked, invalid])

        let applications = try [
            state.applyingCheckedRows(),
            #require(state.applyingAlone(unchecked.id)),
            #require(state.applyingAlone(checked.id))
        ]
        for applied in applications {
            #expect(applied.persistedState.filters == [checked, unchecked])
        }
    }

    @Test("persistedState saves the rows when nothing is applied, marked unapplied")
    func persistedStateSavesADraft() {
        let rows = [
            TestFixtures.makeTableFilter(column: "id", value: "1"),
            TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        ]
        let state = draft(rows)

        #expect(state.persistedState.filters == rows)
        #expect(!state.persistedState.isApplied)
        #expect(state.persistedState.applied == nil)
    }

    @Test("persistedState carries the applied set and marks it applied")
    func persistedStateCarriesTheAppliedSet() {
        let state = draft([TestFixtures.makeTableFilter(column: "id", value: "1")]).applyingCheckedRows()

        #expect(state.persistedState.isApplied)
        #expect(state.persistedState.applied == state.applied)
    }

    // An empty set is what the storage reads as a delete, and Remove All Filters produces one.
    @Test("persistedState saves nothing once the rows are gone")
    func persistedStateIsEmptyWithoutRows() {
        let state = draft([])

        #expect(state.persistedState.filters.isEmpty)
    }

    @Test("persistedState carries the filter logic mode")
    func persistedStateCarriesLogicMode() {
        var state = TabFilterState()
        state.filters = [TestFixtures.makeTableFilter(column: "id", value: "1")]
        state.filterLogicMode = .or

        #expect(state.persistedState.logicMode == .or)
    }

    @Test("A saved state round-trips what was applied, a row applied alone included")
    func persistedStateRoundTripsTheAppliedSet() throws {
        let checked = TestFixtures.makeTableFilter(column: "id", value: "1")
        let other = TestFixtures.makeTableFilter(column: "age", value: "3")
        let unchecked = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        let state = draft([checked, other, unchecked], logicMode: .or)

        let applications = try [state.applyingCheckedRows(), #require(state.applyingAlone(unchecked.id))]
        for applied in applications {
            let decoded = try roundTrip(applied.persistedState)
            #expect(decoded == applied.persistedState)
            #expect(decoded.restoredApplication == applied.applied)
        }
    }

    @Test("A saved state restores what ran, not the draft edited since")
    func persistedStateRestoresWhatRan() throws {
        var state = draft([TestFixtures.makeTableFilter(column: "id", value: "1")]).applyingCheckedRows()
        state.filters[0].value = "2"

        let restored = try roundTrip(state.persistedState).restoredApplication

        #expect(restored?.filters.map(\.value) == ["1"])
    }

    @Test("A file saved without an applied set restores its checked rows")
    func persistedStateWithoutAppliedKeyRestoresCheckedRows() throws {
        let json = Data("""
        {"filters":[{"columnName":"age","filterOperator":">","value":"3","isEnabled":true},\
        {"columnName":"name","filterOperator":"=","value":"a","isEnabled":false}],\
        "logicMode":"OR","isApplied":true}
        """.utf8)

        let decoded = try JSONDecoder().decode(PersistedFilterState.self, from: json)
        let restored = try #require(decoded.restoredApplication)

        #expect(decoded.applied == nil)
        #expect(decoded.filters.count == 2)
        #expect(restored.filters.map(\.columnName) == ["age"])
        #expect(restored.logicMode == .or)
        #expect(restored.aloneFilterID == nil)
    }

    @Test("A state saved unapplied restores nothing")
    func persistedStateUnappliedRestoresNothing() throws {
        let rows = [TestFixtures.makeTableFilter(column: "id", value: "1")]

        #expect(PersistedFilterState(filters: rows, isApplied: false).restoredApplication == nil)
        #expect(PersistedFilterState(filters: rows, applied: nil).restoredApplication == nil)
        #expect(try roundTrip(draft(rows).persistedState).restoredApplication == nil)
    }

    @Test("A running row emptied without Apply is saved as it ran, so the reopened panel shows what runs")
    func persistedStateKeepsAnEmptiedRunningRowAsItRan() throws {
        let running = TestFixtures.makeTableFilter(column: "id", value: "1")
        let unchecked = TestFixtures.makeTableFilter(column: "name", value: "a", isEnabled: false)
        var state = draft([running, unchecked]).applyingCheckedRows()
        var emptied = running
        emptied.value = ""
        emptied.isEnabled = false
        state.updateFilter(emptied)

        let saved = try roundTrip(state.persistedState)

        #expect(saved.filters.map(\.id) == [running.id, unchecked.id])
        #expect(saved.filters.first?.value == "1")
        #expect(saved.filters.first?.isEnabled == false)
        #expect(saved.restoredApplication?.filters == [running])
    }

    @Test("Return on a row applied alone and then emptied stops filtering rather than running the checked rows")
    func applyingCurrentModeWithAnEmptiedAloneRowStops() throws {
        let alone = TestFixtures.makeTableFilter(column: "id", value: "1")
        let other = TestFixtures.makeTableFilter(column: "name", value: "a")
        var state = try #require(draft([alone, other]).applyingAlone(alone.id))
        var emptied = alone
        emptied.value = ""
        state.updateFilter(emptied)

        #expect(state.applyingCurrentMode().applied == nil)
    }

    // The previous stable reads only isApplied.
    @Test("The saved JSON still carries isApplied")
    func persistedStateEncodesIsApplied() throws {
        struct Written: Decodable {
            let isApplied: Bool
        }
        let row = TestFixtures.makeTableFilter(column: "id", value: "1")
        let alone = try #require(draft([row]).applyingAlone(row.id))
        let writtenIsApplied = { (state: TabFilterState) throws -> Bool in
            try JSONDecoder().decode(Written.self, from: JSONEncoder().encode(state.persistedState)).isApplied
        }

        #expect(try writtenIsApplied(alone))
        #expect(try !writtenIsApplied(draft([row])))
    }

    @Test("An applied set with no filters does not decode")
    func appliedFiltersRejectsEmptyFilters() {
        let json = Data(#"{"filters":[],"logicMode":"AND"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppliedFilters.self, from: json)
        }
    }

    @Test("TabFilterState round-trips through Codable including a row applied alone")
    func codableRoundTrip() throws {
        let filter = TestFixtures.makeTableFilter(column: "id", value: "1")
        var state = TabFilterState(isVisible: true)
        state.filters = [filter]
        state = try #require(state.applyingAlone(filter.id))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TabFilterState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.applied?.filters.map(\.id) == [filter.id])
        #expect(decoded.aloneFilterID == filter.id)
    }

    @Test("allEnabledState is false when there are no filters")
    func allEnabledStateEmpty() {
        let state = TabFilterState()
        #expect(state.allEnabledState == false)
    }

    @Test("allEnabledState is true when every filter is enabled")
    func allEnabledStateAllOn() {
        var state = TabFilterState()
        state.filters = [
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name")
        ]
        #expect(state.allEnabledState == true)
    }

    @Test("allEnabledState is false when every filter is disabled")
    func allEnabledStateAllOff() {
        var state = TabFilterState()
        state.filters = [
            TestFixtures.makeTableFilter(column: "id", isEnabled: false),
            TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        ]
        #expect(state.allEnabledState == false)
    }

    @Test("allEnabledState is nil when filters are mixed")
    func allEnabledStateMixed() {
        var state = TabFilterState()
        state.filters = [
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        ]
        #expect(state.allEnabledState == nil)
    }

    @Test("browseSearch reads and writes the key pattern fields")
    func browseSearchAccessor() {
        var state = TabFilterState()
        #expect(!state.hasActiveBrowseSearch)

        state.browseSearch = BrowseSearchState(pattern: "user:*", typeScope: "hash")
        #expect(state.keyPattern == "user:*")
        #expect(state.keyTypeScope == "hash")
        #expect(state.hasActiveBrowseSearch)
        #expect(state.browseSearch == BrowseSearchState(pattern: "user:*", typeScope: "hash"))
    }

    @Test("A type scope alone counts as an active browse search")
    func typeScopeAloneIsActive() {
        var state = TabFilterState()
        state.browseSearch = BrowseSearchState(pattern: "", typeScope: "stream")
        #expect(state.hasActiveBrowseSearch)
    }

    @Test("Legacy JSON without key pattern fields decodes with defaults")
    func decodesLegacyJsonWithoutKeyPatternFields() throws {
        let legacy = Data("""
        {"filters":[],"isVisible":true,"filterLogicMode":"AND"}
        """.utf8)

        let decoded = try JSONDecoder().decode(TabFilterState.self, from: legacy)

        #expect(decoded.isVisible)
        #expect(decoded.keyPattern.isEmpty)
        #expect(decoded.keyTypeScope == nil)
        #expect(!decoded.hasActiveBrowseSearch)
    }

    @Test("Key pattern fields survive a Codable round-trip")
    func browseSearchRoundTrip() throws {
        var state = TabFilterState(isVisible: true)
        state.browseSearch = BrowseSearchState(pattern: "cache:*", typeScope: "string")

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TabFilterState.self, from: data)

        #expect(decoded.keyPattern == "cache:*")
        #expect(decoded.keyTypeScope == "string")
        #expect(decoded == state)
    }
}
