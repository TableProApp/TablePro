//
//  TabFilterStateEditingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TabFilterStateEditingTests {
    private func state(_ filters: [TableFilter]) -> TabFilterState {
        var state = TabFilterState()
        state.filters = filters
        return state
    }

    private func settings(
        _ column: FilterDefaultColumn,
        _ filterOperator: FilterDefaultOperator = .equal
    ) -> FilterSettings {
        FilterSettings(defaultColumn: column, defaultOperator: filterOperator)
    }

    @Test("A new row takes the default column the settings name")
    func newFilterDefaultColumn() {
        let columns = ["id", "name"]
        let resolved = { (column: FilterDefaultColumn, primaryKey: String?, offersRaw: Bool) -> String in
            TabFilterState.newFilter(
                settings: self.settings(column),
                columns: columns,
                primaryKeyColumn: primaryKey,
                offersRawFilter: offersRaw
            ).columnName
        }

        #expect(resolved(.rawSQL, nil, true) == TableFilter.rawSQLColumn)
        #expect(resolved(.primaryKey, "name", true) == "name")
        #expect(resolved(.primaryKey, nil, true) == "id")
        #expect(resolved(.anyColumn, "name", true) == "id")
    }

    @Test("Raw SQL as the default column means the first column when the host offers no raw filter")
    func rawDefaultFallsBackToFirstColumn() {
        let filter = TabFilterState.newFilter(
            settings: settings(.rawSQL),
            columns: ["city", "country"],
            primaryKeyColumn: "country",
            offersRawFilter: false
        )

        #expect(filter.columnName == "city")
        #expect(!filter.isRawSQL)
    }

    @Test("With no columns a new row names none, whatever the default")
    func newFilterWithoutColumns() {
        for column in [FilterDefaultColumn.primaryKey, .anyColumn] {
            let filter = TabFilterState.newFilter(
                settings: settings(column), columns: [], primaryKeyColumn: nil, offersRawFilter: true
            )
            #expect(filter.columnName.isEmpty, "\(column)")
        }
        let rawless = TabFilterState.newFilter(
            settings: settings(.rawSQL), columns: [], primaryKeyColumn: nil, offersRawFilter: false
        )
        #expect(rawless.columnName.isEmpty)
    }

    @Test("A new row takes the default operator and that operator's usual case setting")
    func newFilterOperator() {
        let filter = TabFilterState.newFilter(
            settings: settings(.anyColumn, .contains), columns: ["name"], primaryKeyColumn: nil, offersRawFilter: true
        )

        #expect(filter.filterOperator == .contains)
        #expect(!filter.isCaseSensitive)
        #expect(filter.value.isEmpty)
        #expect(filter.isEnabled)
    }

    @Test("Adding a row appends it and hands back its id")
    func addFilterAppends() {
        var state = state([TestFixtures.makeTableFilter(column: "id")])

        let id = state.addFilter(
            settings: settings(.anyColumn), columns: ["name"], primaryKeyColumn: nil, offersRawFilter: true
        )

        #expect(state.filters.count == 2)
        #expect(state.filters.last?.id == id)
        #expect(state.filters.last?.columnName == "name")
    }

    @Test("A row's add button puts the new row right under it")
    func addFilterAfterARow() {
        let first = TestFixtures.makeTableFilter(column: "id")
        let last = TestFixtures.makeTableFilter(column: "name")
        var state = state([first, last])

        let id = state.addFilter(
            settings: settings(.anyColumn), columns: ["name"], primaryKeyColumn: nil, offersRawFilter: true,
            after: first.id
        )

        #expect(state.filters.map(\.id) == [first.id, id, last.id])
    }

    @Test("Filtering with a column adds a row for it and opens the panel")
    func addFilterForColumn() {
        var state = TabFilterState()

        state.addFilter(forColumn: "email", settings: settings(.rawSQL, .contains))

        #expect(state.filters.map(\.columnName) == ["email"])
        #expect(state.filters.first?.filterOperator == .contains)
        #expect(state.filters.first?.isCaseSensitive == false)
        #expect(state.isVisible)
    }

    @Test("A duplicate lands after its source and copies the condition")
    func duplicateInsertsAfterSource() {
        let first = TestFixtures.makeTableFilter(column: "id", op: .between, value: "1", secondValue: "9")
        let second = TestFixtures.makeTableFilter(column: "name")
        var state = state([first, second])

        let copyID = state.duplicateFilter(first)

        #expect(state.filters.map(\.id) == [first.id, copyID, second.id])
        let copy = state.filters[1]
        #expect(copy.id != first.id)
        #expect(copy.columnName == "id")
        #expect(copy.filterOperator == .between)
        #expect(copy.value == "1")
        #expect(copy.secondValue == "9")
    }

    @Test("A duplicate keeps its source's case setting and element scope")
    func duplicateKeepsCaseAndScope() throws {
        var source = TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a")
        source.isCaseSensitive = true
        source.elementScope = "tags"
        var state = state([source])

        let copyID = state.duplicateFilter(source)

        let copy = try #require(state.filters.first { $0.id == copyID })
        #expect(copy.isCaseSensitive)
        #expect(copy.elementScope == "tags")
        #expect(copy.hasSameCondition(as: source))
    }

    @Test("A duplicate of a raw row carries its condition")
    func duplicateRawRow() {
        let source = TableFilter.rawCondition("id > 5")
        var state = state([source])

        let copyID = state.duplicateFilter(source)

        #expect(state.filters.first { $0.id == copyID }?.value == "id > 5")
    }

    @Test("Duplicating a row the state no longer holds appends the copy")
    func duplicateOfMissingRowAppends() {
        let kept = TestFixtures.makeTableFilter(column: "id")
        var state = state([kept])

        let copyID = state.duplicateFilter(TestFixtures.makeTableFilter(column: "gone"))

        #expect(state.filters.map(\.id) == [kept.id, copyID])
    }

    @Test("Updating a row replaces it by id and ignores an unknown row")
    func updateFilterById() {
        var row = TestFixtures.makeTableFilter(column: "id", value: "1")
        var state = state([row])

        row.value = "2"
        state.updateFilter(row)
        state.updateFilter(TestFixtures.makeTableFilter(column: "other"))

        #expect(state.filters == [row])
    }

    @Test("Removing the row applied alone stops filtering, removing another keeps it alone")
    func removingTheAloneRowStopsFiltering() throws {
        let first = TestFixtures.makeTableFilter(column: "id")
        let second = TestFixtures.makeTableFilter(column: "name")
        let alone = try #require(state([first, second]).applyingAlone(second.id))

        let withoutAlone = alone.removingFilter(second.id)
        #expect(withoutAlone.filters == [first])
        #expect(withoutAlone.applied == nil)
        #expect(!withoutAlone.isFiltering)

        let withoutOther = alone.removingFilter(first.id)
        #expect(withoutOther.applied == alone.applied)
        #expect(withoutOther.aloneFilterID == second.id)

        let all = state([first, second]).applyingCheckedRows()
        #expect(all.removingFilter(first.id).applied == AppliedFilters.checkedRows(of: [second], logicMode: .and))
    }

    @Test("Removing a row reruns what ran without it, and a row that never ran changes nothing")
    func removingFilterReachesWhatRuns() {
        let first = TestFixtures.makeTableFilter(column: "id")
        let second = TestFixtures.makeTableFilter(column: "name")
        let draft = TestFixtures.makeTableFilter(column: "email", value: "")

        let running = state([first, second, draft]).applyingCheckedRows()
        #expect(running.removingFilter(draft.id).applied == running.applied)
        let withoutFirst = running.removingFilter(first.id)
        #expect(withoutFirst.applied?.filters == [second])
        #expect(withoutFirst.removingFilter(second.id).applied == nil)

        #expect(state([first]).removingFilter(first.id).applied == nil)
    }

    @Test("Removing a running row leaves the rest running as they ran, an unapplied edit staying a draft")
    func removingRunningRowKeepsTheRestAsTheyRan() {
        let age = TableFilter(columnName: "age", value: "10")
        let city = TableFilter(columnName: "city", value: "Paris")
        var state = state([age, city]).applyingCheckedRows()
        state.isVisible = true
        state.filters[1].value = "London"

        let next = state.removingFilter(age.id)

        #expect(next.filters.map(\.value) == ["London"])
        #expect(next.applied?.filters == [city])
        #expect(next.applied?.logicMode == .and)
        #expect(next.status == .changesNotApplied)
        #expect(next.isVisible)
    }

    @Test("Removing a row that is not running leaves what runs unchanged")
    func removingRowNotRunningKeepsApplied() {
        let running = TestFixtures.makeTableFilter(column: "id")
        let unchecked = TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        var state = state([running, unchecked]).applyingCheckedRows()
        let typedAfterApply = TestFixtures.makeTableFilter(column: "email", value: "a")
        state.filters.append(typedAfterApply)
        #expect(state.status == .changesNotApplied)

        let withoutUnchecked = state.removingFilter(unchecked.id)
        #expect(withoutUnchecked.applied == state.applied)

        let withoutTyped = state.removingFilter(typedAfterApply.id)
        #expect(withoutTyped.applied == state.applied)
        #expect(withoutTyped.status == .applied)
    }

    @Test("Removing the last row hides the bar")
    func removingLastRowHidesTheBar() {
        let row = TestFixtures.makeTableFilter(column: "id")
        var running = state([row]).applyingCheckedRows()
        running.isVisible = true
        var unapplied = state([row])
        unapplied.isVisible = true

        for state in [running, unapplied] {
            let next = state.removingFilter(row.id)
            #expect(next.filters.isEmpty)
            #expect(next.applied == nil)
            #expect(!next.isVisible)
        }
    }

    @Test("Remove All hides the bar and stops filtering")
    func removingAllFilters() {
        var state = state([
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name")
        ]).applyingCheckedRows()
        state.isVisible = true

        let next = state.removingAllFilters()

        #expect(next.filters.isEmpty)
        #expect(!next.isFiltering)
        #expect(!next.isVisible)
    }

    @Test("Applying in the current mode keeps a row applied alone alone")
    func applyingCurrentModeKeepsAlone() throws {
        let alone = TestFixtures.makeTableFilter(column: "id", value: "1")
        let draft = state([alone, TestFixtures.makeTableFilter(column: "name")])
        var applied = try #require(draft.applyingAlone(alone.id))
        applied.filters[0].value = "2"

        let next = applied.applyingCurrentMode()

        #expect(next.aloneFilterID == alone.id)
        #expect(next.applied?.filters.map(\.value) == ["2"])
        #expect(next.status == .appliedAlone)
    }

    @Test("Applying in the current mode with no row alone applies the checked rows")
    func applyingCurrentModeAppliesCheckedRows() {
        let checked = TestFixtures.makeTableFilter(column: "id", value: "1")
        let unchecked = TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        var state = state([checked, unchecked])

        state = state.applyingCurrentMode()
        #expect(state.applied == AppliedFilters.checkedRows(of: [checked], logicMode: .and))

        state.filters[0].value = "2"
        state = state.applyingCurrentMode()
        #expect(state.applied?.filters.map(\.value) == ["2"])
        #expect(state.aloneFilterID == nil)
    }

    @Test("The header checkbox turns every row on or off")
    func setAllFiltersEnabled() {
        var state = state([
            TestFixtures.makeTableFilter(column: "id"),
            TestFixtures.makeTableFilter(column: "name", isEnabled: false)
        ])

        state.setAllFiltersEnabled(true)
        #expect(state.allEnabledState == true)

        state.setAllFiltersEnabled(false)
        #expect(state.allEnabledState == false)
    }

    @Test("Clearing drops the rows and what runs and leaves the panel open")
    func clearFilters() {
        var state = state([TestFixtures.makeTableFilter(column: "id")]).applyingCheckedRows()
        state.isVisible = true

        state.clearFilters()

        #expect(state.filters.isEmpty)
        #expect(state.applied == nil)
        #expect(state.isVisible)
    }

    @Test("Loading a preset with no logic mode replaces only the rows")
    func loadPreset() {
        let presetRow = TestFixtures.makeTableFilter(column: "name")
        var state = state([TestFixtures.makeTableFilter(column: "id")]).applyingCheckedRows()
        state.filterLogicMode = .or
        let applied = state.applied

        state.loadPreset(FilterPreset(name: "Names", filters: [presetRow]))

        #expect(state.filters == [presetRow])
        #expect(state.applied == applied)
        #expect(state.filterLogicMode == .or)
    }

    @Test("A reference filter runs alone under Match all with the panel open")
    func setReferenceFilter() {
        let reference = TestFixtures.makeTableFilter(column: "user_id", value: "7")
        var state = state([TestFixtures.makeTableFilter(column: "id")])
        state.filterLogicMode = .or

        state.setReferenceFilter(reference)

        #expect(state.filters == [reference])
        #expect(state.applied == AppliedFilters.checkedRows(of: [reference], logicMode: .and))
        #expect(state.isVisible)
        #expect(state.filterLogicMode == .and)
    }

    @Test("A cross-column search is one enabled CONTAINS row per column")
    func crossColumnSearchFilters() {
        let filters = TabFilterState.crossColumnSearchFilters(term: "ana", columns: ["name", "email"])

        #expect(filters.map(\.columnName) == ["name", "email"])
        #expect(filters.allSatisfy { $0.filterOperator == .contains && $0.value == "ana" && $0.isEnabled })
    }

    @Test("Search All Rows writes its rows into the draft and runs them under Match any")
    func searchingAllRows() {
        let next = state([TestFixtures.makeTableFilter(column: "id")])
            .searchingAllRows(term: "ana", columns: ["name", "email"])

        #expect(next.filters.map(\.columnName) == ["name", "email"])
        #expect(next.filters.allSatisfy { $0.filterOperator == .contains && $0.value == "ana" && $0.isEnabled })
        #expect(next.filterLogicMode == .or)
        #expect(next.applied?.filters == next.filters)
        #expect(next.applied?.logicMode == .or)
        #expect(next.isVisible)
        #expect(next.status == .applied)
    }

    @Test("What reruns is what ran, whatever the draft says since")
    func rerunReadsRunningFilters() {
        var state = state([TableFilter(columnName: "age", value: "10")]).applyingCheckedRows()
        #expect(state.applied?.filters.map(\.value) == ["10"])

        state.filters[0] = state.filters[0].selectingRawCondition()
        state.filterLogicMode = .or

        #expect(state.applied?.filters.map(\.columnName) == ["age"])
        #expect(state.applied?.logicMode == .and)

        #expect(state.turningOff().applied == nil)
    }

    @Test("Removing a running row whose text was erased without Apply still stops it running")
    func removingEditedRunningRowStopsIt() {
        let running = TableFilter(columnName: "age", value: "10")
        var state = state([running]).applyingCheckedRows()
        state.filters[0].value = ""

        #expect(state.removingFilter(running.id).applied == nil)
    }

    @Test("Renaming or removing a column carries what is running along with the draft")
    func columnEditsReachRunningFilters() {
        var state = state([TableFilter(columnName: "city", value: "Paris"), TableFilter(columnName: "age", value: "3")])
            .applyingCheckedRows()

        state.renameFilterColumn(from: "city", to: "town")
        #expect(state.applied?.filters.map(\.columnName) == ["town", "age"])
        #expect(state.filters.map(\.columnName) == ["town", "age"])

        state.removeFilters(onColumns: ["age"])
        #expect(state.applied?.filters.map(\.columnName) == ["town"])
        #expect(state.filters.map(\.columnName) == ["town"])
    }

    @Test("A cross-column search ignores case, like the find that offers it")
    func crossColumnSearchIgnoresCase() {
        let filters = TabFilterState.crossColumnSearchFilters(term: "ana", columns: ["name", "email"])

        #expect(filters.allSatisfy { !$0.isCaseSensitive })
    }

    @Test("Moving a row by direction or onto another row reorders the rows")
    func moveFilter() {
        let first = TestFixtures.makeTableFilter(column: "a")
        let second = TestFixtures.makeTableFilter(column: "b")
        let third = TestFixtures.makeTableFilter(column: "c")
        var state = state([first, second, third])

        state.moveFilter(first.id, direction: .down)
        #expect(state.filters.map(\.columnName) == ["b", "a", "c"])

        state.moveFilter(third.id, onto: second.id)
        #expect(state.filters.map(\.columnName) == ["c", "b", "a"])

        state.moveFilter(third.id, direction: .up)
        #expect(state.filters.map(\.columnName) == ["c", "b", "a"])
        #expect(!state.canMoveFilter(third.id, direction: .up))
        #expect(state.canMoveFilter(third.id, direction: .down))
        #expect(!state.canMoveFilter(first.id, direction: .down))
    }
}
