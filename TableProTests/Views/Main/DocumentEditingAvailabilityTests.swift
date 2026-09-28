//
//  DocumentEditingAvailabilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct DocumentEditingAvailabilityTests {
    private let locators: [String?] = [#"{"$numberInt":"1"}"#, #"{"$numberInt":"2"}"#, nil, #"{"$numberInt":"4"}"#]

    private func makeCoordinator(
        type: DatabaseType = .mongodb,
        tabType: TabType = .table,
        locators: [String?]? = nil
    ) -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = tabType == .table
            ? QueryTab(title: "people", query: "db.people.find({})", tabType: .table, tableName: "people")
            : QueryTab(title: "Query", query: "db.people.find({})", tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        tab.tableContext.isEditable = true
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")], [.text("3"), .text("Cleo")],
                            [.text("4"), .text("Bob")]],
                columns: ["_id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                rowLocators: locators ?? self.locators
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "people",
            columns: ["_id", "name"],
            primaryKeyColumns: ["_id"],
            databaseType: type,
            generatedColumns: []
        )
        return coordinator
    }

    @Test("A collection row the driver gave a locator can be edited as a document")
    func offeredOnALocatedRow() {
        let coordinator = makeCoordinator()
        #expect(coordinator.documentEditingAvailable)
        #expect(coordinator.canEditDocument(atDisplayRow: 0))
        #expect(coordinator.documentLocator(forDisplayRow: 1) == #"{"$numberInt":"2"}"#)
    }

    @Test("A row with no locator, or no row at all, is not offered")
    func notOfferedWithoutALocator() {
        let coordinator = makeCoordinator()
        #expect(!coordinator.canEditDocument(atDisplayRow: 2))
        #expect(!coordinator.canEditDocument(atDisplayRow: 9))
    }

    @Test("A value filter resolves the shown row to its own document, not the one at that storage index")
    func valueFilterResolvesDisplayRows() throws {
        let coordinator = makeCoordinator()
        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["Bob"], includesNull: false), columnName: "name", forColumn: 1)
        coordinator.setValueFilter(filter, forTab: tabId)

        #expect(coordinator.documentLocator(forDisplayRow: 0) == #"{"$numberInt":"2"}"#)
        #expect(coordinator.documentLocator(forDisplayRow: 1) == #"{"$numberInt":"4"}"#)
    }

    @Test("A query tab never offers Edit Document, whatever its rows carry")
    func queryTabIsNotOffered() {
        let coordinator = makeCoordinator(tabType: .query)
        #expect(!coordinator.documentEditingAvailable)
        #expect(!coordinator.canEditDocument(atDisplayRow: 0))
    }

    @Test("Staged grid edits keep Edit Document away")
    func stagedChangesAreRefused() {
        let coordinator = makeCoordinator()
        coordinator.changeManager.recordCellChange(
            rowID: .existing(1),
            columnIndex: 1,
            columnName: "name",
            oldValue: .text("Bob"),
            newValue: .text("Rob"),
            originalRow: [.text("2"), .text("Bob")]
        )
        #expect(coordinator.changeManager.hasChanges)
        #expect(!coordinator.canEditDocument(atDisplayRow: 0))
    }

    @Test("A read-only connection does not offer Edit Document")
    func readOnlyIsRefused() {
        let coordinator = makeCoordinator()
        coordinator.toolbarState.safeModeLevel = .readOnly
        #expect(!coordinator.canEditDocument(atDisplayRow: 0))
    }

    @Test("An engine that stores rows does not offer it")
    func rowEngineIsRefused() {
        let coordinator = makeCoordinator(type: .postgresql)
        #expect(!coordinator.canEditDocument(atDisplayRow: 0))
    }

    @Test("The sheet opens on the locator it was given, as an edit of that collection")
    func presentsAnEdit() {
        let coordinator = makeCoordinator()
        coordinator.presentEditDocument(locator: #"{"$numberInt":"4"}"#)
        guard case .documentEditor(let request) = coordinator.activeSheet else {
            Issue.record("Expected the document editor")
            return
        }
        #expect(request.table == "people")
        #expect(request.kind == .edit(locator: #"{"$numberInt":"4"}"#))
    }
}
