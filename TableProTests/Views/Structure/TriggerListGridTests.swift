//
//  TriggerListGridTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TriggerListGridTests {
    private let triggers = [
        TriggerInfo(name: "trg_b", timing: "BEFORE", event: "UPDATE", statement: "", enabled: true),
        TriggerInfo(name: "trg_a", timing: "AFTER", event: "INSERT", statement: "", enabled: false),
        TriggerInfo(name: "trg_c", timing: "AFTER", event: "DELETE", statement: ""),
    ]

    private func sort(_ column: Int, _ direction: SortDirection) -> SortState {
        SortState(columns: [SortColumn(columnIndex: column, direction: direction)], source: .user)
    }

    private func names(_ list: [TriggerInfo]) -> [String] {
        list.map(\.name)
    }

    private func load(_ grid: StructureListGridModel<TriggerInfo.ID>, _ state: TriggerInspectorState, key: Int) {
        let rows = state.displayed(triggers).map {
            StructureListRow(id: $0.id, values: TriggerListColumns.values(for: $0, showsEnabled: true))
        }
        _ = grid.ensureLoaded(key: key, columns: TriggerListColumns.titles(showsEnabled: true)) { rows }
    }

    @Test("The list opens sorted by name, ascending")
    func opensSortedByName() {
        let state = TriggerInspectorState()
        #expect(names(state.displayed(triggers)) == ["trg_a", "trg_b", "trg_c"])
    }

    @Test("A header sort orders by that column, in either direction, with ties kept in arrival order")
    func sortsByColumn() {
        let state = TriggerInspectorState()
        state.sortState = sort(1, .ascending)
        #expect(names(state.displayed(triggers)) == ["trg_a", "trg_c", "trg_b"])

        state.sortState = sort(2, .descending)
        #expect(names(state.displayed(triggers)) == ["trg_b", "trg_a", "trg_c"])

        state.sortState = SortState(columns: [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 0, direction: .descending),
        ], source: .user)
        #expect(names(state.displayed(triggers)) == ["trg_c", "trg_a", "trg_b"])
    }

    @Test("Don't Sort shows the triggers in the order the server listed them")
    func clearedSortKeepsArrivalOrder() {
        let state = TriggerInspectorState()
        state.sortState = SortState(columns: [], source: .user)
        #expect(names(state.displayed(triggers)) == ["trg_b", "trg_a", "trg_c"])
    }

    @Test("The filter matches the trigger name only")
    func filtersByName() {
        let state = TriggerInspectorState()
        state.searchText = "_C"
        #expect(names(state.displayed(triggers)) == ["trg_c"])
        state.searchText = "DELETE"
        #expect(state.displayed(triggers).isEmpty)
    }

    @Test("Enabled reads YES or NO, blank where the engine does not say, and only when some trigger says")
    func enabledColumn() {
        #expect(TriggerListColumns.titles(showsEnabled: false).count == 3)
        #expect(TriggerListColumns.titles(showsEnabled: true).count == 4)
        #expect(TriggerListColumns.values(for: triggers[0], showsEnabled: true) == ["trg_b", "BEFORE", "UPDATE", "YES"])
        #expect(TriggerListColumns.values(for: triggers[1], showsEnabled: true).last == "NO")
        #expect(TriggerListColumns.values(for: triggers[2], showsEnabled: true).last?.isEmpty == true)
        #expect(TriggerListColumns.values(for: triggers[0], showsEnabled: false) == ["trg_b", "BEFORE", "UPDATE"])
    }

    @Test("A selected trigger keeps its row through a sort")
    func selectionFollowsTheTriggerThroughASort() {
        let state = TriggerInspectorState()
        let grid = StructureListGridModel<TriggerInfo.ID>(restoresSelectionAfterReload: true)
        load(grid, state, key: 1)
        state.select(grid.ids(atDisplayRows: [1]))
        #expect(state.selectedTrigger(triggers)?.name == "trg_b")

        state.sortState = sort(0, .descending)
        load(grid, state, key: 2)

        #expect(grid.displayRows(of: state.selectedIDs) == [1])
        state.sortState = sort(2, .ascending)
        load(grid, state, key: 3)
        #expect(names(state.displayed(triggers)) == ["trg_c", "trg_a", "trg_b"])
        #expect(grid.displayRows(of: state.selectedIDs) == [2])
        #expect(state.selectedTrigger(triggers)?.name == "trg_b")
    }

    @Test("Edit and Delete act on one trigger and have none while several are selected")
    func actionTargetIsSingle() {
        let state = TriggerInspectorState()
        #expect(state.actionTarget(triggers)?.name == "trg_a")

        state.select([triggers[2].id])
        #expect(state.actionTarget(triggers)?.name == "trg_c")

        state.select([triggers[0].id, triggers[2].id])
        #expect(state.actionTarget(triggers) == nil)
        #expect(state.selectedTrigger(triggers)?.name == "trg_b")
    }

    @Test("A refresh keeps the selected triggers that remain and falls back to the first otherwise")
    func ensureSelectionPrunesAndFallsBack() {
        let state = TriggerInspectorState()
        state.ensureSelection(triggers)
        #expect(state.selectedIDs == [triggers[0].id])

        state.select([triggers[1].id, "gone"])
        state.ensureSelection(triggers)
        #expect(state.selectedIDs == [triggers[1].id])

        state.select(["gone"])
        state.ensureSelection(triggers)
        #expect(state.selectedIDs == [triggers[0].id])

        state.ensureSelection([])
        #expect(state.selectedIDs.isEmpty)
    }
}
