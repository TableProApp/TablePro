//
//  ResultReplacementEditsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ResultReplacementEditsTests {
    private func stageEdit(in tabId: UUID, of fixture: CoordinatorFixture) {
        let edits = fixture.coordinator.changeManager(forTab: tabId)
        edits.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        edits.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["1", "a"]
        )
    }

    private func presentResult(in tabId: UUID, of fixture: CoordinatorFixture) {
        fixture.coordinator.queryExecutionCoordinator.presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming(total: 0),
            totalRowsAffected: 0,
            newResultSets: [ResultSet(label: "orders", tableRows: TableRows())],
            sessionNotice: nil
        )
    }

    private func select(_ tabId: UUID, from outgoing: UUID?, in fixture: CoordinatorFixture) {
        fixture.tabManager.selectedTabId = tabId
        fixture.coordinator.handleTabChange(from: outgoing, to: tabId, tabs: fixture.tabManager.tabs)
    }

    @Test("A result installed on a background tab drops only that tab's edits")
    func backgroundResultDropsItsTabsEdits() {
        let fixture = CoordinatorFixture()
        let background = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        stageEdit(in: background.id, of: fixture)
        let selected = fixture.addTab(QueryTab(title: "B", query: "SELECT * FROM users", tabType: .query))
        stageEdit(in: selected.id, of: fixture)

        presentResult(in: background.id, of: fixture)

        #expect(!fixture.coordinator.hasStagedRowEdits(inTab: background.id))
        #expect(fixture.coordinator.hasStagedRowEdits(inTab: selected.id))
        #expect(fixture.changeManager.hasChanges)
    }

    @Test("A result installed on the selected tab drops its edits")
    func selectedResultDropsItsEdits() {
        let fixture = CoordinatorFixture()
        let selected = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        stageEdit(in: selected.id, of: fixture)

        presentResult(in: selected.id, of: fixture)

        #expect(!fixture.changeManager.hasChanges)
    }

    @Test("A result that lands while the selection moves drops the edits of the tab it replaced")
    func resultLandingDuringASwitchDropsItsTabsEdits() {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        stageEdit(in: edited.id, of: fixture)

        // The selection moved, the handler has not run yet, and the run finishes in between.
        fixture.tabManager.selectedTabId = other.id
        presentResult(in: edited.id, of: fixture)
        fixture.coordinator.handleTabChange(from: edited.id, to: other.id, tabs: fixture.tabManager.tabs)
        #expect(!fixture.coordinator.hasStagedRowEdits(inTab: edited.id))

        select(edited.id, from: other.id, in: fixture)
        #expect(!fixture.changeManager.hasChanges)
    }

    @Test("Switching away and back keeps the tab's edits in its own manager")
    func switchingBackKeepsTheEdits() {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        stageEdit(in: edited.id, of: fixture)
        let edits = fixture.coordinator.changeManager(forTab: edited.id)

        select(other.id, from: edited.id, in: fixture)
        #expect(!fixture.changeManager.hasChanges)
        #expect(edits.hasChanges)

        select(edited.id, from: other.id, in: fixture)
        #expect(fixture.changeManager === edits)
        #expect(edits.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("Renaming a table moves a background tab's staged edits to the new name")
    func renameRetargetsABackgroundTabsEdits() {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
        stageEdit(in: edited.id, of: fixture)
        fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query))

        fixture.coordinator.retitleTabs(ids: [edited.id], to: "people")

        #expect(fixture.coordinator.changeManager(forTab: edited.id).tableName == "people")
        #expect(fixture.coordinator.hasStagedRowEdits(inTab: edited.id))
    }

    @Test("Edits staged after a reselect the switch handler never saw stay with their tab")
    func reselectWithoutTheHandlerKeepsLaterEdits() {
        let fixture = CoordinatorFixture()
        let edited = fixture.addTab(QueryTab(title: "A", query: "SELECT * FROM users", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)
        let third = fixture.addTab(QueryTab(title: "C", query: "SELECT 2", tabType: .query), select: false)

        // A to B and back inside one update, and no handler runs.
        fixture.tabManager.selectedTabId = other.id
        fixture.tabManager.selectedTabId = edited.id
        stageEdit(in: edited.id, of: fixture)

        select(third.id, from: edited.id, in: fixture)

        #expect(fixture.coordinator.hasStagedRowEdits(inTab: edited.id))
        #expect(!fixture.changeManager.hasChanges)
    }
}
