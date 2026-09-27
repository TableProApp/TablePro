//
//  TableRowsRefreshPlanTests.swift
//  TableProTests
//
//  A change to one table used to reload whichever tab each window had in front, whatever table it
//  showed, and asked that tab to discard its edits first, while the background tabs that did show
//  the table kept their old rows.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TableRowsRefreshPlanTests {
    private func tableTab(_ name: String, mode: ResultsViewMode = .data) -> QueryTab {
        var tab = QueryTab(title: name, query: "SELECT 1", tabType: .table, tableName: name)
        tab.display.resultsViewMode = mode
        return tab
    }

    private let changedAt = ContinuousClock.now

    private var rowsChange: TableFreshness.Change {
        TableFreshness.Change(extent: .rows, at: changedAt)
    }

    private func state(
        _ tab: QueryTab,
        holdsEdits: Bool = false,
        load: TableRowsRefreshPlan.SelectedTabLoad = .idle
    ) -> TableRowsRefreshPlan.SelectedTabState {
        TableRowsRefreshPlan.SelectedTabState(id: tab.id, holdsEdits: holdsEdits, load: load)
    }

    private func showsUsers(_ tab: QueryTab) -> Bool {
        tab.tableContext.tableName == "users"
    }

    @Test("Marks every table tab on the table and nothing else, query tabs included")
    func marksOnlyTheAddressedTableTabs() {
        let first = tableTab("users")
        let second = tableTab("users")
        let orders = tableTab("orders")
        let query = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .query, tableName: "users")

        let plan = TableRowsRefreshPlan(
            tabs: [first, orders, query, second],
            selectedTab: state(orders),
            change: rowsChange,
            where: showsUsers
        )

        #expect(plan.staleTabIds == [first.id, second.id])
        #expect(plan.selectedTabAction == .noReload)
    }

    @Test("Reloads the selected tab now when it is on the table and nothing of the user's is in it")
    func reloadsACleanSelectedTab() {
        let selected = tableTab("users")

        let plan = TableRowsRefreshPlan(tabs: [selected], selectedTab: state(selected), change: rowsChange, where: showsUsers)

        #expect(plan.staleTabIds == [selected.id])
        #expect(plan.selectedTabAction == .reloadNow)
    }

    @Test("Leaves a selected tab holding edits or an open cell editor marked, and reloads nothing")
    func leavesASelectedTabWithEditsMarked() {
        let selected = tableTab("users")

        let plan = TableRowsRefreshPlan(
            tabs: [selected],
            selectedTab: state(selected, holdsEdits: true),
            change: rowsChange,
            where: showsUsers
        )

        #expect(plan.staleTabIds == [selected.id])
        #expect(plan.selectedTabAction == .noReload)
    }

    @Test("Leaves a load that claimed the tab after the change to finish, since it reads what was written")
    func leavesALoadThatStartedAfterTheChange() {
        let selected = tableTab("users")

        let plan = TableRowsRefreshPlan(
            tabs: [selected],
            selectedTab: state(selected, load: .running(startedAt: changedAt.advanced(by: .milliseconds(1)))),
            change: rowsChange,
            where: showsUsers
        )

        #expect(plan.staleTabIds == [selected.id])
        #expect(plan.selectedTabAction == .noReload)
    }

    @Test("Starts again a load that claimed the tab before the change, whose rows are out of date")
    func restartsALoadThatStartedBeforeTheChange() {
        let selected = tableTab("users")
        let structure = tableTab("users", mode: .structure)
        let running = TableRowsRefreshPlan.SelectedTabLoad.running(startedAt: changedAt.advanced(by: .milliseconds(-1)))

        let plan = TableRowsRefreshPlan(
            tabs: [selected],
            selectedTab: state(selected, load: running),
            change: rowsChange,
            where: showsUsers
        )
        let behindStructure = TableRowsRefreshPlan(
            tabs: [structure],
            selectedTab: state(structure, load: running),
            change: rowsChange,
            where: showsUsers
        )

        #expect(plan.selectedTabAction == .reloadNow)
        #expect(behindStructure.selectedTabAction == .reloadBehindStructure)
    }

    @Test("Starts again any running load after a definition change, since it chose its metadata before the mark")
    func restartsAnyRunningLoadAfterADefinitionChange() {
        let selected = tableTab("users")

        let plan = TableRowsRefreshPlan(
            tabs: [selected],
            selectedTab: state(selected, load: .running(startedAt: changedAt.advanced(by: .milliseconds(1)))),
            change: TableFreshness.Change(extent: .definition, at: changedAt),
            where: showsUsers
        )

        #expect(plan.selectedTabAction == .reloadNow)
    }

    @Test("Leaves a scheduled load, which has not read yet, and Fetch All, which extends rows it does not own")
    func leavesAScheduledOrExtendingLoad() {
        let selected = tableTab("users")
        let definition = TableFreshness.Change(extent: .definition, at: changedAt)

        for load in [TableRowsRefreshPlan.SelectedTabLoad.scheduled, .extending] {
            for change in [rowsChange, definition] {
                let plan = TableRowsRefreshPlan(
                    tabs: [selected],
                    selectedTab: state(selected, load: load),
                    change: change,
                    where: showsUsers
                )

                #expect(plan.staleTabIds == [selected.id])
                #expect(plan.selectedTabAction == .noReload, "\(load) \(change.extent)")
            }
        }
    }

    @Test("Starts nothing again for a selected tab holding edits, whatever is running")
    func leavesARunningLoadOnATabWithEdits() {
        let selected = tableTab("users")

        let plan = TableRowsRefreshPlan(
            tabs: [selected],
            selectedTab: state(
                selected,
                holdsEdits: true,
                load: .running(startedAt: changedAt.advanced(by: .milliseconds(-1)))
            ),
            change: rowsChange,
            where: showsUsers
        )

        #expect(plan.selectedTabAction == .noReload)
    }

    @Test("Reloads the rows behind a selected tab showing its structure")
    func reloadsBehindTheStructureView() {
        let selected = tableTab("users", mode: .structure)

        let plan = TableRowsRefreshPlan(tabs: [selected], selectedTab: state(selected), change: rowsChange, where: showsUsers)

        #expect(plan.staleTabIds == [selected.id])
        #expect(plan.selectedTabAction == .reloadBehindStructure)
    }

    @Test("Reloads a selected tab drawing its rows as JSON or a chart like one drawing a grid")
    func reloadsEveryRowsMode() {
        for mode in [ResultsViewMode.json, .chart, .map] {
            let selected = tableTab("users", mode: mode)

            let plan = TableRowsRefreshPlan(tabs: [selected], selectedTab: state(selected), change: rowsChange, where: showsUsers)

            #expect(plan.selectedTabAction == .reloadNow, "mode \(mode)")
        }
    }

    @Test("Leaves out the tab that made the change, selected or not")
    func leavesOutTheOriginTab() {
        let origin = tableTab("users")
        let duplicate = tableTab("users")

        let plan = TableRowsRefreshPlan(
            tabs: [origin, duplicate],
            selectedTab: state(origin),
            change: rowsChange,
            excludingTabId: origin.id,
            where: showsUsers
        )

        #expect(plan.staleTabIds == [duplicate.id])
        #expect(plan.selectedTabAction == .noReload)
    }

    @Test("A window with no tab selected still marks its tabs")
    func marksWithNoSelection() {
        let background = tableTab("users")

        let plan = TableRowsRefreshPlan(tabs: [background], selectedTab: nil, change: rowsChange, where: showsUsers)

        #expect(plan.staleTabIds == [background.id])
        #expect(plan.selectedTabAction == .noReload)
    }

    @Test("A change the selected tab owes is acted on once the edits in the way are gone, and not before")
    func anOwedChangeWaitsForTheEditsInTheWay() {
        let selected = tableTab("users")
        let behindStructure = tableTab("users", mode: .structure)

        #expect(
            TableRowsRefreshPlan.resumedAction(for: selected, state: state(selected, holdsEdits: true), owing: rowsChange)
                == .noReload
        )
        #expect(TableRowsRefreshPlan.resumedAction(for: selected, state: state(selected), owing: rowsChange) == .reloadNow)
        #expect(
            TableRowsRefreshPlan.resumedAction(for: behindStructure, state: state(behindStructure), owing: rowsChange)
                == .reloadBehindStructure
        )
        #expect(
            TableRowsRefreshPlan.resumedAction(for: selected, state: state(selected, load: .scheduled), owing: rowsChange)
                == .noReload
        )
    }

    /// A tab switch or a save that cleans the change manager has started the tab's own load by the
    /// time the resume is asked. That load claimed the tab after the change, with the mark in place,
    /// so starting it again would run the same query twice, a definition change included.
    @Test("An owed change leaves the tab's own load running when it claimed the tab after the change")
    func anOwedChangeLeavesALoadStartedAfterIt() {
        let selected = tableTab("users")
        let definition = TableFreshness.Change(extent: .definition, at: changedAt)
        let after = TableRowsRefreshPlan.SelectedTabLoad.running(startedAt: changedAt.advanced(by: .milliseconds(1)))
        let before = TableRowsRefreshPlan.SelectedTabLoad.running(startedAt: changedAt.advanced(by: .milliseconds(-1)))

        for change in [rowsChange, definition] {
            #expect(
                TableRowsRefreshPlan.resumedAction(for: selected, state: state(selected, load: after), owing: change)
                    == .noReload,
                "\(change.extent)"
            )
            #expect(
                TableRowsRefreshPlan.resumedAction(for: selected, state: state(selected, load: before), owing: change)
                    == .reloadNow,
                "\(change.extent)"
            )
        }
    }
}
