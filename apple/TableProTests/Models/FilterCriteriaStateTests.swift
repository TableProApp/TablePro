//
//  FilterCriteriaStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct FilterCriteriaStateTests {
    private static let columns = ["id", "name", "email"]

    private func builderState(_ filters: [TableFilter], commit: FilterCommit? = nil) -> TabFilterState {
        TabFilterState(filters: filters, commit: commit, isVisible: true, filterLogicMode: .or)
    }

    // MARK: - Builder and Text

    @Test("Builder to Text holds one raw row with the rows' condition, and Text to Builder keeps it as that row")
    func builderToTextToBuilderKeepsTypedText() throws {
        let name = TestFixtures.makeTableFilter(column: "name", value: "a")
        let email = TestFixtures.makeTableFilter(column: "email", value: "b")
        var state = builderState([name, email])

        let rowID = state.enterTextMode(condition: "`name` = 'a' OR `email` = 'b'")

        #expect(state.effectiveEditMode == .text)
        #expect(state.filters.count == 1)
        #expect(state.filters.first?.isRawSQL == true)
        #expect(state.filters.first?.id == rowID)
        #expect(state.textCondition == "`name` = 'a' OR `email` = 'b'")
        #expect(state.filterLogicMode == .and)

        state.setTextCondition("`name` = 'c'")
        state.enterBuilderMode()

        #expect(state.effectiveEditMode == .builder)
        #expect(state.editMode == .builder)
        let row = try #require(state.filters.first)
        #expect(state.filters.count == 1)
        #expect(row.isRawSQL)
        #expect(row.value == "`name` = 'c'")
        #expect(state.textModeOrigin == nil)
    }

    @Test("Text to Builder with nothing typed brings the rows back with their flags and logic mode")
    func untouchedRoundTripRestoresRows() {
        let enabled = TestFixtures.makeTableFilter(column: "name", value: "a")
        let disabled = TestFixtures.makeTableFilter(column: "email", value: "b", isEnabled: false)
        var state = builderState([enabled, disabled])

        state.enterTextMode(condition: "`name` = 'a'")
        state.enterBuilderMode()

        #expect(state.filters == [enabled, disabled])
        #expect(state.filterLogicMode == .or)
        #expect(state.effectiveEditMode == .builder)
    }

    @Test("A solo commit reads as every row once its row is gone, and no commit stays none")
    func enteringTextModeKeepsTheCommitResolvable() {
        let row = TestFixtures.makeTableFilter(column: "name", value: "a")
        var solo = builderState([row], commit: .solo(row.id))
        solo.enterTextMode(condition: "`name` = 'a'")
        #expect(solo.commit == .all)

        var none = builderState([row])
        none.enterTextMode(condition: "`name` = 'a'")
        #expect(none.commit == nil)
    }

    @Test("Rows put in from outside the editor leave Text mode")
    func outsideRowsLeaveTextMode() {
        var state = builderState([])
        state.enterTextMode(condition: "")
        #expect(state.effectiveEditMode == .text)

        state.addFilter(forColumn: "name", settings: FilterSettings())

        #expect(state.editMode == .builder)
        #expect(state.effectiveEditMode == .builder)
        #expect(state.textModeOrigin == nil)
    }

    @Test("A text mode whose rows are not one raw row reads as Builder")
    func misshapenTextStateReadsAsBuilder() {
        var state = builderState([TestFixtures.makeTableFilter(column: "name", value: "a")])
        state.editMode = .text
        #expect(state.effectiveEditMode == .builder)
        #expect(state.textCondition.isEmpty)

        state.setTextCondition("ignored")
        #expect(state.filters.first?.value == "a")
    }

    @Test("The edit mode persists with the tab and with the table's saved filters, and older files read as Builder")
    func editModePersists() throws {
        var state = builderState([])
        state.enterTextMode(condition: "id > 1")

        let tabData = try JSONEncoder().encode(state)
        let decodedTab = try JSONDecoder().decode(TabFilterState.self, from: tabData)
        #expect(decodedTab.editMode == .text)
        #expect(decodedTab.effectiveEditMode == .text)

        let savedData = try JSONEncoder().encode(state.persistedState)
        let decodedSaved = try JSONDecoder().decode(PersistedFilterState.self, from: savedData)
        #expect(decodedSaved.editMode == .text)

        let legacyTab = try JSONDecoder().decode(TabFilterState.self, from: Data(#"{"filters":[]}"#.utf8))
        #expect(legacyTab.editMode == .builder)
        let legacySaved = try JSONDecoder().decode(PersistedFilterState.self, from: Data(#"{"filters":[]}"#.utf8))
        #expect(legacySaved.editMode == .builder)
    }

    @Test("Restoring a table's saved Text mode brings it back, and nothing saved starts in Builder")
    @MainActor
    func restoreReadsTheSavedMode() {
        let raw = TableFilter.rawCondition("id > 1")
        let restored = FilterCoordinator.resolvedRestoredState(
            settings: FilterSettings(restoreBehavior: .restoreAndApply),
            saved: PersistedFilterState(filters: [raw], editMode: .text),
            current: TabFilterState()
        )
        #expect(restored.effectiveEditMode == .text)

        var current = TabFilterState()
        current.sortDraft = [FilterSortCriterion(columnName: "id", direction: .ascending)]
        let empty = FilterCoordinator.resolvedRestoredState(
            settings: FilterSettings(restoreBehavior: .restoreAndApply),
            saved: PersistedFilterState(filters: [], editMode: .text),
            current: current
        )
        #expect(empty.editMode == .builder)
        #expect(empty.sortDraft == nil)
    }

    // MARK: - Sort draft

    @Test("The section shows the tab's sort until an edit seeds a draft from it")
    func sortDraftSeedsFromTheTabSort() {
        let applied = [FilterSortCriterion(columnName: "name", direction: .descending)]
        var state = TabFilterState()
        #expect(state.sortCriteria(applied: applied) == applied)
        #expect(state.sortDraft == nil)

        state.addSortCriterion(applied: applied, columns: Self.columns, direction: .ascending)

        #expect(state.sortDraft == [
            FilterSortCriterion(columnName: "name", direction: .descending),
            FilterSortCriterion(columnName: "id", direction: .ascending)
        ])
    }

    @Test("Keys stay unique: + takes an unused column, and a change to a column another key sorts by is refused")
    func sortKeysStayUnique() {
        var state = TabFilterState()
        for _ in 0..<4 {
            state.addSortCriterion(applied: [], columns: Self.columns, direction: .ascending)
        }
        #expect(state.sortDraft?.map { $0.columnName } == Self.columns)

        state.updateSortCriterion(
            "id",
            to: FilterSortCriterion(columnName: "email", direction: .descending),
            applied: []
        )
        #expect(state.sortDraft?.first == FilterSortCriterion(columnName: "id", direction: .ascending))

        state.updateSortCriterion(
            "id",
            to: FilterSortCriterion(columnName: "id", direction: .descending),
            applied: []
        )
        #expect(state.sortDraft?.first?.direction == .descending)

        state.removeSortCriterion("name", applied: [])
        #expect(state.sortDraft?.map { $0.columnName } == ["id", "email"])
    }

    @Test("The tab's sort converts to section keys by name and back to a stamped user sort")
    func sortConversionRoundTrips() {
        let tabSort = SortState(
            columns: [
                SortColumn(columnIndex: 2, direction: .descending),
                SortColumn(columnIndex: 0, direction: .ascending, columnName: "id"),
                SortColumn(columnIndex: 0, direction: .descending, columnName: "id"),
                SortColumn(columnIndex: 9, direction: .ascending)
            ],
            source: .defaultSort
        )

        let criteria = TabFilterState.sortCriteria(from: tabSort, columns: Self.columns)
        #expect(criteria == [
            FilterSortCriterion(columnName: "email", direction: .descending),
            FilterSortCriterion(columnName: "id", direction: .ascending)
        ])

        let sort = TabFilterState.sortState(
            from: criteria + [FilterSortCriterion(columnName: "gone", direction: .ascending)],
            columns: Self.columns
        )
        #expect(sort.source == .user)
        #expect(sort.columns == [
            SortColumn(columnIndex: 2, direction: .descending, columnName: "email"),
            SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")
        ])
    }

    // MARK: - Edited state

    @Test("Edited compares what Apply would run with what the rows were fetched with")
    func editedFollowsTheRunningFilters() {
        let name = TestFixtures.makeTableFilter(column: "name", value: "a")
        var state = builderState([name], commit: .all)
        state.filterLogicMode = .and
        state.adoptAppliedFiltersAsRunning()
        #expect(!state.criteriaDiffer(fromAppliedSort: []))

        var unfinished = state
        unfinished.filters.append(TestFixtures.makeTableFilter(column: "", value: ""))
        #expect(!unfinished.criteriaDiffer(fromAppliedSort: []), "an incomplete row runs nothing")

        var typed = state
        typed.filters[0].value = "b"
        #expect(typed.criteriaDiffer(fromAppliedSort: []))

        var unchecked = state
        unchecked.filters[0].isEnabled = false
        #expect(unchecked.criteriaDiffer(fromAppliedSort: []))

        var cleared = state
        cleared.commit = nil
        cleared.adoptAppliedFiltersAsRunning()
        #expect(cleared.criteriaDiffer(fromAppliedSort: []), "Apply would filter rows shown unfiltered")
    }

    @Test("Edited sees a changed logic mode only when it joins two rows")
    func editedLogicMode() {
        let name = TestFixtures.makeTableFilter(column: "name", value: "a")
        let email = TestFixtures.makeTableFilter(column: "email", value: "b")
        var two = builderState([name, email], commit: .all)
        two.filterLogicMode = .and
        two.adoptAppliedFiltersAsRunning()
        two.filterLogicMode = .or
        #expect(two.criteriaDiffer(fromAppliedSort: []))

        var one = builderState([name], commit: .all)
        one.filterLogicMode = .and
        one.adoptAppliedFiltersAsRunning()
        one.filterLogicMode = .or
        #expect(!one.criteriaDiffer(fromAppliedSort: []))
    }

    @Test("Edited sees a sort draft only while it differs from the tab's sort")
    func editedSortDraft() {
        let applied = [FilterSortCriterion(columnName: "name", direction: .ascending)]
        var state = TabFilterState()
        #expect(!state.criteriaDiffer(fromAppliedSort: applied))

        state.updateSortCriterion(
            "name",
            to: FilterSortCriterion(columnName: "name", direction: .descending),
            applied: applied
        )
        #expect(state.criteriaDiffer(fromAppliedSort: applied))

        state.updateSortCriterion(
            "name",
            to: FilterSortCriterion(columnName: "name", direction: .ascending),
            applied: applied
        )
        #expect(!state.criteriaDiffer(fromAppliedSort: applied))
    }
}
