//
//  TabFilterStateEditingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TabFilterState editing")
struct TabFilterStateEditingTests {
    private func state(_ filters: [TableFilter], commit: FilterCommit? = nil) -> TabFilterState {
        var state = TabFilterState()
        state.filters = filters
        state.commit = commit
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

    @Test("A new row takes the default operator and keeps the case setting it has always had")
    func newFilterOperator() {
        let filter = TabFilterState.newFilter(
            settings: settings(.anyColumn, .contains), columns: ["name"], primaryKeyColumn: nil, offersRawFilter: true
        )

        #expect(filter.filterOperator == .contains)
        #expect(filter.isCaseSensitive)
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

    @Test("Filtering with a column adds a row for it and opens the panel")
    func addFilterForColumn() {
        var state = TabFilterState()

        state.addFilter(forColumn: "email", settings: settings(.rawSQL, .contains))

        #expect(state.filters.map(\.columnName) == ["email"])
        #expect(state.filters.first?.filterOperator == .contains)
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

    @Test("A duplicate keeps the operator's case default and no element scope, as it always has")
    func duplicateDropsCaseAndScope() {
        var source = TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a")
        source.isCaseSensitive = true
        source.elementScope = "tags"
        var state = state([source])

        state.duplicateFilter(source)

        #expect(state.filters.last?.isCaseSensitive == false)
        #expect(state.filters.last?.elementScope == nil)
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

    @Test("Removing the soloed row drops the commit, removing another keeps it")
    func removeFilterClearsOnlyItsSoloCommit() {
        let first = TestFixtures.makeTableFilter(column: "id")
        let second = TestFixtures.makeTableFilter(column: "name")

        var soloed = state([first, second], commit: .solo(second.id))
        soloed.removeFilter(second)
        #expect(soloed.filters == [first])
        #expect(soloed.commit == nil)

        var other = state([first, second], commit: .solo(second.id))
        other.removeFilter(first)
        #expect(other.commit == .solo(second.id))

        var all = state([first, second], commit: .all)
        all.removeFilter(first)
        #expect(all.commit == .all)
    }

    @Test("Removing a row reports the reload the rows on screen now need")
    func removeFilterReportsReload() {
        let first = TestFixtures.makeTableFilter(column: "id")
        let second = TestFixtures.makeTableFilter(column: "name")
        let draft = TestFixtures.makeTableFilter(column: "email", value: "")

        var running = state([first, second, draft], commit: .all)
        #expect(running.removeFilter(draft) == .noChange)
        #expect(running.removeFilter(first) == .reapply([second]))
        #expect(running.removeFilter(second) == .clear)

        var unapplied = state([first])
        #expect(unapplied.removeFilter(first) == .noChange)
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

    @Test("Clearing drops the rows and the commit and leaves the panel open")
    func clearFilters() {
        var state = state([TestFixtures.makeTableFilter(column: "id")], commit: .all)
        state.isVisible = true

        state.clearFilters()

        #expect(state.filters.isEmpty)
        #expect(state.commit == nil)
        #expect(state.isVisible)
    }

    @Test("Loading a preset replaces the rows and nothing else")
    func loadPreset() {
        let presetRow = TestFixtures.makeTableFilter(column: "name")
        var state = state([TestFixtures.makeTableFilter(column: "id")], commit: .all)
        state.filterLogicMode = .or

        state.loadPreset(FilterPreset(name: "Names", filters: [presetRow]))

        #expect(state.filters == [presetRow])
        #expect(state.commit == .all)
        #expect(state.filterLogicMode == .or)
    }

    @Test("A reference filter runs alone under Match all with the panel open")
    func setReferenceFilter() {
        let reference = TestFixtures.makeTableFilter(column: "user_id", value: "7")
        var state = state([TestFixtures.makeTableFilter(column: "id")])
        state.filterLogicMode = .or

        state.setReferenceFilter(reference)

        #expect(state.filters == [reference])
        #expect(state.commit == .all)
        #expect(state.isVisible)
        #expect(state.filterLogicMode == .and)
    }

    @Test("A single filter replaces the rows and runs, and an invalid one changes nothing")
    func applySingleFilter() {
        let existing = TestFixtures.makeTableFilter(column: "id")
        let single = TestFixtures.makeTableFilter(column: "name", value: "a")
        var state = state([existing])
        state.filterLogicMode = .or

        state.applySingleFilter(TestFixtures.makeTableFilter(column: "", value: ""))
        #expect(state.filters == [existing])
        #expect(state.commit == nil)

        state.applySingleFilter(single)
        #expect(state.filters == [single])
        #expect(state.commit == .all)
        #expect(state.isVisible)
        #expect(state.filterLogicMode == .or)
    }

    @Test("A cross-column search is one enabled CONTAINS row per column")
    func crossColumnSearchFilters() {
        let filters = TabFilterState.crossColumnSearchFilters(term: "ana", columns: ["name", "email"])

        #expect(filters.map(\.columnName) == ["name", "email"])
        #expect(filters.allSatisfy { $0.filterOperator == .contains && $0.value == "ana" && $0.isEnabled })
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
