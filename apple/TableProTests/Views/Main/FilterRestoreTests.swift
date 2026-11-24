//
//  FilterRestoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct FilterRestoreTests {
    private func settings(
        _ behavior: FilterRestoreBehavior,
        alwaysShowPanel: Bool = false
    ) -> FilterSettings {
        FilterSettings(restoreBehavior: behavior, alwaysShowPanel: alwaysShowPanel)
    }

    @Test("Restore and apply runs the saved filters and shows the bar")
    func restoreAndApplyRunsSavedFilters() {
        let saved = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: saved),
            current: TabFilterState()
        )

        #expect(result.filters == saved)
        #expect(result.applied?.filters == saved)
        #expect(result.isVisible)
    }

    @Test("Restore and apply leaves a saved draft unapplied")
    func restoreAndApplyKeepsADraftDraft() {
        let saved = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: saved, isApplied: false),
            current: TabFilterState()
        )

        #expect(result.filters == saved)
        #expect(result.applied == nil)
        #expect(!result.isFiltering)
        #expect(result.isVisible)
    }

    @Test("Restore without applying shows a filter that was running without running it")
    func restoreWithoutApplyingDowngradesAnAppliedFilter() {
        let saved = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreWithoutApplying),
            saved: PersistedFilterState(filters: saved, isApplied: true),
            current: TabFilterState()
        )

        #expect(result.filters == saved)
        #expect(result.applied == nil)
        #expect(!result.isFiltering)
        #expect(result.isVisible)
    }

    @Test("Restore without applying runs nothing, not even a saved snapshot")
    func restoreWithoutApplyingIgnoresTheSnapshot() throws {
        let alone = TestFixtures.makeTableFilter(column: "name", value: "bob", isEnabled: false)
        let snapshot = try #require(AppliedFilters.alone(alone, logicMode: .and))

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreWithoutApplying),
            saved: PersistedFilterState(filters: [alone], applied: snapshot),
            current: TabFilterState()
        )

        #expect(result.filters == [alone])
        #expect(result.applied == nil)
        #expect(result.isVisible)
    }

    @Test("A table with nothing saved restores with nothing applied")
    func emptyRestoreAppliesNothing() {
        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: []),
            current: TabFilterState(isVisible: true)
        )

        #expect(result.applied == nil)
        #expect(!result.isVisible)
    }

    @Test("A row typed into an empty restored panel is not applied until Apply")
    func typingIntoAnEmptyRestoredPanelAppliesNothing() {
        var state = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: []),
            current: TabFilterState()
        )

        state.filters = [TestFixtures.makeTableFilter(column: "id", value: "5")]

        #expect(state.applied == nil)
        #expect(!state.isFiltering)
        #expect(state.status == .notApplied)
    }

    @Test("Restore brings back the saved logic mode instead of defaulting to AND")
    func restoreBringsBackLogicMode() {
        let saved = [
            TestFixtures.makeTableFilter(column: "a"),
            TestFixtures.makeTableFilter(column: "b"),
        ]

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: saved, logicMode: .or),
            current: TabFilterState()
        )

        #expect(result.filterLogicMode == .or)
    }

    @Test("Restore keeps disabled filters in the panel but out of the applied set")
    func restoreKeepsDisabledFilterInactive() {
        let active = TestFixtures.makeTableFilter(column: "email", value: "a@b.com")
        let inactive = TestFixtures.makeTableFilter(column: "name", value: "bob", isEnabled: false)

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: [active, inactive]),
            current: TabFilterState()
        )

        #expect(result.filters == [active, inactive])
        #expect(result.applied?.filters == [active])
        #expect(result.isVisible)
    }

    // A row typed after the last apply comes back as a draft, so reopening never runs what the grid never showed.
    @Test("Restore and apply runs the saved snapshot, not the checked rows")
    func restoreAndApplyRunsTheSavedSnapshot() throws {
        let ran = TestFixtures.makeTableFilter(column: "email", value: "a@b.com")
        let typedLater = TestFixtures.makeTableFilter(column: "name", value: "bob")
        let snapshot = try #require(AppliedFilters.checkedRows(of: [ran], logicMode: .and))

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: [ran, typedLater], logicMode: .and, applied: snapshot),
            current: TabFilterState()
        )

        #expect(result.filters == [ran, typedLater])
        #expect(result.applied == snapshot)
        #expect(result.status == .changesNotApplied)
    }

    @Test("Restore and apply runs a row that was applied alone, alone")
    func restoreAndApplyRunsARowAppliedAlone() throws {
        let checked = TestFixtures.makeTableFilter(column: "email", value: "a@b.com")
        let alone = TestFixtures.makeTableFilter(column: "name", value: "bob", isEnabled: false)
        let snapshot = try #require(AppliedFilters.alone(alone, logicMode: .and))

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: [checked, alone], applied: snapshot),
            current: TabFilterState()
        )

        #expect(result.applied == snapshot)
        #expect(result.aloneFilterID == alone.id)
        #expect(result.filters.map(\.isEnabled) == [true, false])
        #expect(result.status == .appliedAlone)
    }

    @Test("Restore and apply runs a row unchecked after it ran, as the grid last showed it")
    func restoreAndApplyRunsAnUncheckedRowFromTheSnapshot() throws {
        let first = TestFixtures.makeTableFilter(column: "email", value: "a@b.com")
        let unchecked = TestFixtures.makeTableFilter(column: "name", value: "bob", isEnabled: false)
        var ranChecked = unchecked
        ranChecked.isEnabled = true
        let snapshot = try #require(AppliedFilters(filters: [first, ranChecked], logicMode: .or))

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: [first, unchecked], logicMode: .or, applied: snapshot),
            current: TabFilterState()
        )

        #expect(result.applied == snapshot)
        #expect(result.filters.map(\.isEnabled) == [true, false])
        #expect(result.status == .changesNotApplied)
    }

    @Test("A saved file from before the snapshot runs its checked rows")
    func restoreAndApplyRunsTheCheckedRowsOfAnOlderFile() throws {
        let first = TestFixtures.makeTableFilter(column: "email", value: "a@b.com")
        let second = TestFixtures.makeTableFilter(column: "name", value: "bob")
        let unchecked = TestFixtures.makeTableFilter(column: "id", value: "5", isEnabled: false)
        let rowsData = try JSONEncoder().encode([first, second, unchecked])
        let rows = try #require(String(data: rowsData, encoding: .utf8))
        let file = Data(#"{"filters":\#(rows),"logicMode":"OR","isApplied":true}"#.utf8)
        let saved = try JSONDecoder().decode(PersistedFilterState.self, from: file)
        let checkedRows = try #require(AppliedFilters.checkedRows(of: [first, second], logicMode: .or))

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: saved,
            current: TabFilterState()
        )

        #expect(saved.applied == nil)
        #expect(result.filters == [first, second, unchecked])
        #expect(result.applied == checkedRows)
    }

    @Test("Always show reveals the bar even without saved filters")
    func alwaysShowRevealsBarWithoutFilters() {
        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply, alwaysShowPanel: true),
            saved: PersistedFilterState(filters: []),
            current: TabFilterState()
        )

        #expect(result.applied == nil)
        #expect(result.isVisible)
    }

    @Test("Don't save restores nothing and hides the bar")
    func dontSaveRestoresNothing() throws {
        let saved = [TestFixtures.makeTableFilter(column: "email")]
        let snapshot = try #require(AppliedFilters.checkedRows(of: saved, logicMode: .and))

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.dontSave),
            saved: PersistedFilterState(filters: saved, applied: snapshot),
            current: TabFilterState(isVisible: true)
        )

        #expect(result.filters.isEmpty)
        #expect(result.applied == nil)
        #expect(!result.isVisible)
    }

    @Test("Don't save still honours always show")
    func dontSaveHonoursAlwaysShow() {
        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.dontSave, alwaysShowPanel: true),
            saved: PersistedFilterState(filters: [TestFixtures.makeTableFilter(column: "email")]),
            current: TabFilterState()
        )

        #expect(result.filters.isEmpty)
        #expect(result.isVisible)
    }

    @Test("Removing a filter that isn't running leaves what runs alone")
    func removeUnappliedFilterIsNoChange() {
        let running = TestFixtures.makeTableFilter(column: "email")
        let other = TestFixtures.makeTableFilter(column: "name")
        var state = TabFilterState.applying([running], logicMode: .and)
        state.filters.append(other)

        let next = state.removingFilter(other.id)

        #expect(next.filters == [running])
        #expect(next.applied == state.applied)
    }

    @Test("Removing the only running filter stops filtering and hides the bar")
    func removeOnlyAppliedFilterClears() {
        let only = TestFixtures.makeTableFilter(column: "email")

        let next = TabFilterState.applying([only], logicMode: .and).removingFilter(only.id)

        #expect(next.applied == nil)
        #expect(!next.isVisible)
    }

    @Test("Removing one of several running filters keeps the rest running")
    func removeOneOfSeveralReappliesRemainder() {
        let first = TestFixtures.makeTableFilter(column: "email")
        let second = TestFixtures.makeTableFilter(column: "name")

        let next = TabFilterState.applying([first, second], logicMode: .and).removingFilter(first.id)

        #expect(next.applied?.filters == [second])
    }
}
