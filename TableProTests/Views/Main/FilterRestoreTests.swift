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
    @Test("Restore Last applies saved filters and shows the bar")
    func restoreLastAppliesSavedFiltersAndShowsBar() {
        let saved = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let result = FilterCoordinator.resolvedRestoredState(
            panelState: .restoreLast,
            saved: saved,
            current: TabFilterState()
        )

        #expect(result.filters == saved)
        #expect(result.appliedFilters == saved)
        #expect(result.isVisible)
    }

    @Test("Restore Last with no saved filters keeps the bar hidden")
    func restoreLastWithNoFiltersKeepsBarHidden() {
        let result = FilterCoordinator.resolvedRestoredState(
            panelState: .restoreLast,
            saved: [],
            current: TabFilterState(isVisible: true)
        )

        #expect(result.appliedFilters.isEmpty)
        #expect(!result.isVisible)
    }

    @Test("Always Show reveals the bar even without saved filters")
    func alwaysShowRevealsBarWithoutFilters() {
        let result = FilterCoordinator.resolvedRestoredState(
            panelState: .alwaysShow,
            saved: [],
            current: TabFilterState()
        )

        #expect(result.appliedFilters.isEmpty)
        #expect(result.isVisible)
    }

    @Test("Always Hide never restores filters or shows the bar")
    func alwaysHideRestoresNothing() {
        let saved = [TestFixtures.makeTableFilter(column: "email")]

        let result = FilterCoordinator.resolvedRestoredState(
            panelState: .alwaysHide,
            saved: saved,
            current: TabFilterState()
        )

        #expect(result.filters.isEmpty)
        #expect(result.appliedFilters.isEmpty)
        #expect(!result.isVisible)
    }

    @Test("Always Hide overrides a visible current bar")
    func alwaysHideOverridesVisibleBar() {
        let result = FilterCoordinator.resolvedRestoredState(
            panelState: .alwaysHide,
            saved: [],
            current: TabFilterState(isVisible: true)
        )

        #expect(result.filters.isEmpty)
        #expect(result.appliedFilters.isEmpty)
        #expect(!result.isVisible)
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
