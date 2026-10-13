//
//  TriggerListGridTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
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

    @Test("Each column opens at the width the list has always given it")
    func defaultWidths() {
        #expect(TriggerListColumns.widths(showsEnabled: true) == [220, 90, 150, 70])
        #expect(TriggerListColumns.widths(showsEnabled: false) == [240, 90, 160])
        #expect(TriggerListColumns.widths(showsEnabled: true).count == TriggerListColumns.titles(showsEnabled: true).count)
        #expect(TriggerListColumns.widths(showsEnabled: false).count == TriggerListColumns.titles(showsEnabled: false).count)
    }

    @Test("Enabled reads aloud as Enabled or Disabled, and says nothing where the engine does not")
    func enabledIsSpokenByName() {
        let enabled = TriggerListColumns.enabledColumn
        #expect(TriggerListColumns.titles(showsEnabled: true)[enabled] == String(localized: "Enabled"))
        #expect(TriggerListColumns.spokenValues(for: triggers[0], showsEnabled: true) == [enabled: String(localized: "Enabled")])
        #expect(TriggerListColumns.spokenValues(for: triggers[1], showsEnabled: true) == [enabled: String(localized: "Disabled")])
        #expect(TriggerListColumns.spokenValues(for: triggers[2], showsEnabled: true).isEmpty)
        #expect(TriggerListColumns.spokenValues(for: triggers[0], showsEnabled: false).isEmpty)
    }

    @Test("Each column keeps the minimum width the list has always given it")
    func minimumWidths() {
        #expect(TriggerListColumns.minimumWidths(showsEnabled: true) == [140, 70, 90, 60])
        #expect(TriggerListColumns.minimumWidths(showsEnabled: false) == [140, 70, 90])
        for showsEnabled in [true, false] {
            let minimums = TriggerListColumns.minimumWidths(showsEnabled: showsEnabled)
            #expect(minimums.count == TriggerListColumns.titles(showsEnabled: showsEnabled).count)
            #expect(zip(minimums, TriggerListColumns.widths(showsEnabled: showsEnabled)).allSatisfy { $0 <= $1 })
        }
    }

    private func tableView(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let tableView = view as? KeyHandlingTableView { return tableView }
        return view.subviews.lazy.compactMap { self.tableView(in: $0) }.first
    }

    @Test("The list's columns carry their minimum widths into the grid")
    func gridColumnsCarryTheirMinimums() throws {
        let window = ThemeTestFixture.host(
            TriggerListPane(triggers: triggers, databaseType: .mysql, state: TriggerInspectorState()),
            size: NSSize(width: 700, height: 300)
        )
        let tableView = try #require(tableView(in: window.contentView))
        let presented = tableView.tableColumns.filter { $0.identifier != ColumnIdentitySchema.rowNumberIdentifier && !$0.isHidden }
        let minimums = Dictionary(uniqueKeysWithValues: presented.map { ($0.headerCell.stringValue, $0.minWidth) })

        let titles = TriggerListColumns.titles(showsEnabled: true)
        #expect(minimums == Dictionary(uniqueKeysWithValues: zip(titles, TriggerListColumns.minimumWidths(showsEnabled: true))))
        withExtendedLifetime(window) {}
    }

    @Test("A selected trigger keeps its row through a sort")
    func selectionFollowsTheTriggerThroughASort() {
        let state = TriggerInspectorState()
        let grid = StructureListGridModel<TriggerInfo.ID>()
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
