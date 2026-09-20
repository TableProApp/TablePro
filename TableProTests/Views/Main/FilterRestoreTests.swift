//
//  FilterRestoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FilterRestore")
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
        #expect(result.appliedFilters == saved)
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
        #expect(result.commit == nil)
        #expect(!result.hasAppliedFilters)
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
        #expect(result.commit == nil)
        #expect(!result.hasAppliedFilters)
        #expect(result.isVisible)
    }

    @Test("A table with nothing saved restores with nothing committed")
    func emptyRestoreCommitsNothing() {
        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply),
            saved: PersistedFilterState(filters: []),
            current: TabFilterState(isVisible: true)
        )

        #expect(result.commit == nil)
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

        #expect(state.appliedFilters.isEmpty)
        #expect(!state.hasAppliedFilters)
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
        #expect(result.appliedFilters == [active])
        #expect(result.isVisible)
    }

    @Test("Always show reveals the bar even without saved filters")
    func alwaysShowRevealsBarWithoutFilters() {
        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.restoreAndApply, alwaysShowPanel: true),
            saved: PersistedFilterState(filters: []),
            current: TabFilterState()
        )

        #expect(result.appliedFilters.isEmpty)
        #expect(result.isVisible)
    }

    @Test("Don't save restores nothing and hides the bar")
    func dontSaveRestoresNothing() {
        let saved = [TestFixtures.makeTableFilter(column: "email")]

        let result = FilterCoordinator.resolvedRestoredState(
            settings: settings(.dontSave),
            saved: PersistedFilterState(filters: saved),
            current: TabFilterState(isVisible: true)
        )

        #expect(result.filters.isEmpty)
        #expect(result.appliedFilters.isEmpty)
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

    @Test("Removing a filter that isn't applied changes nothing")
    func removeUnappliedFilterIsNoChange() {
        let applied = TestFixtures.makeTableFilter(column: "email")
        let other = TestFixtures.makeTableFilter(column: "name")
        #expect(FilterCoordinator.removeFilterOutcome(removing: other, from: [applied]) == .noChange)
    }

    @Test("Removing the only applied filter clears")
    func removeOnlyAppliedFilterClears() {
        let only = TestFixtures.makeTableFilter(column: "email")
        #expect(FilterCoordinator.removeFilterOutcome(removing: only, from: [only]) == .clear)
    }

    @Test("Removing one of several applied filters reapplies the rest")
    func removeOneOfSeveralReappliesRemainder() {
        let first = TestFixtures.makeTableFilter(column: "email")
        let second = TestFixtures.makeTableFilter(column: "name")
        #expect(
            FilterCoordinator.removeFilterOutcome(removing: first, from: [first, second]) == .reapply([second])
        )
    }
}
