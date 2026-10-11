//
//  MaterializedViewRowWriteTests.swift
//  TableProTests
//
//  PostgreSQL 17.11 refuses every row write on a materialized view ("cannot change materialized
//  view"), and the sidebar opened one as an editable table, so the edits queued and failed at Save.
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class MaterializedViewClipboard: ClipboardProvider {
    var gridRows: GridRowsClipboardPayload?

    func readText() -> String? { nil }
    func readGridRows() -> GridRowsClipboardPayload? { gridRows }
    func writeText(_ text: String) {}
    func writeCsv(_ csv: String) {}
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {}
    var hasText: Bool { false }
    var hasGridRows: Bool { gridRows != nil }
}

@MainActor
struct MaterializedViewRowWriteTests {
    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "shop", type: .postgresql),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    private func finishLoad(_ coordinator: MainContentCoordinator) throws {
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        coordinator.tabManager.tabs[index].tableContext.isEditable = true
        coordinator.tabManager.tabs[index].display.resultsViewMode = .data
        let tabId = coordinator.tabManager.tabs[index].id
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tabId
        )
        coordinator.changeManager.configureForTable(
            tableName: coordinator.tabManager.tabs[index].tableContext.tableName ?? "",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
    }

    private func openedFromSidebar(_ type: TableInfo.TableType) throws -> MainContentCoordinator {
        let coordinator = makeCoordinator()
        coordinator.openTableTab(TableInfo(name: "daily_totals", type: type, rowCount: nil, schema: "public"))
        try finishLoad(coordinator)
        return coordinator
    }

    private func restoredTab(objectType: TableInfo.TableType?, isView: Bool) throws -> MainContentCoordinator {
        var tab = QueryTab(
            title: "daily_totals",
            query: "SELECT * FROM daily_totals",
            tabType: .table,
            tableName: "daily_totals"
        )
        tab.tableContext.isView = isView
        tab.tableContext.objectType = objectType
        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)

        let coordinator = makeCoordinator()
        coordinator.tabManager.tabs.append(restored)
        coordinator.tabManager.selectedTabId = restored.id
        try finishLoad(coordinator)
        return coordinator
    }

    private func rowCount(_ coordinator: MainContentCoordinator) throws -> Int {
        let tabId = try #require(coordinator.tabManager.selectedTabId)
        return coordinator.tabSessionRegistry.tableRows(for: tabId).count
    }

    // MARK: - Opening from the sidebar

    @Test("A materialized view opened from the sidebar refuses row edits and Add Row")
    func sidebarMaterializedViewIsReadOnly() throws {
        let coordinator = try openedFromSidebar(.materializedView)
        defer { coordinator.teardown() }

        let context = try #require(coordinator.tabManager.selectedTab?.tableContext)
        #expect(context.isView)
        #expect(context.objectType == .materializedView)
        #expect(!coordinator.canEditActiveResult)
        #expect(!coordinator.canAddRow)
    }

    @Test("A table opened from the sidebar the same way still edits and adds rows")
    func sidebarTableStaysWritable() throws {
        let coordinator = try openedFromSidebar(.table)
        defer { coordinator.teardown() }

        #expect(coordinator.tabManager.selectedTab?.tableContext.isView == false)
        #expect(coordinator.canEditActiveResult)
        #expect(coordinator.canAddRow)
    }

    @Test("The sidebar and Open Quickly open a materialized view with the same gate")
    func sidebarAndOpenQuicklyAgree() throws {
        let fromSidebar = try openedFromSidebar(.materializedView)
        defer { fromSidebar.teardown() }

        let fromSwitcher = makeCoordinator()
        defer { fromSwitcher.teardown() }
        let target = QuickSwitcherTarget(
            connectionId: fromSwitcher.connectionId,
            connectionName: "Primary",
            databaseName: "shop",
            schemaName: "public"
        )
        let item = try #require(
            QuickSwitcherViewModel.makeCrossConnectionItems(
                tables: [TableInfo(name: "daily_totals", type: .materializedView, rowCount: nil)],
                target: target,
                connectionSwitchesDatabases: true
            ).first
        )
        fromSwitcher.handleQuickSwitcherSelection(item)
        try finishLoad(fromSwitcher)

        let sidebarContext = try #require(fromSidebar.tabManager.selectedTab?.tableContext)
        let switcherContext = try #require(fromSwitcher.tabManager.selectedTab?.tableContext)
        #expect(sidebarContext.isView == switcherContext.isView)
        #expect(sidebarContext.objectType == switcherContext.objectType)
        #expect(fromSidebar.canEditActiveResult == fromSwitcher.canEditActiveResult)
        #expect(!fromSwitcher.canEditActiveResult)
    }

    // MARK: - A tab saved by an older build

    @Test("A restored tab that kept isView false over a materialized view stays read-only")
    func restoredStaleTabIsReadOnly() throws {
        let coordinator = try restoredTab(objectType: .materializedView, isView: false)
        defer { coordinator.teardown() }

        let context = try #require(coordinator.tabManager.selectedTab?.tableContext)
        #expect(context.isEditable)
        #expect(!context.isView)
        #expect(!coordinator.canEditActiveResult)
        #expect(!coordinator.canAddRow)
    }

    @Test("A restored table tab with the same history still edits and adds rows")
    func restoredTableTabStaysWritable() throws {
        let coordinator = try restoredTab(objectType: .table, isView: false)
        defer { coordinator.teardown() }

        #expect(coordinator.canEditActiveResult)
        #expect(coordinator.canAddRow)
    }

    @Test("A restored tab with no kind follows its Bool")
    func restoredTabWithoutAKindFollowsTheBool() throws {
        let writable = try restoredTab(objectType: nil, isView: false)
        defer { writable.teardown() }
        let readOnly = try restoredTab(objectType: nil, isView: true)
        defer { readOnly.teardown() }

        #expect(writable.canEditActiveResult)
        #expect(!readOnly.canEditActiveResult)
    }

    // MARK: - The row commands themselves

    @Test("Add, Duplicate, Delete and Paste stage nothing on a materialized view")
    func rowCommandsRefuseAMaterializedView() throws {
        let clipboard = MaterializedViewClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(columns: ["id", "name"], rows: [[.text("3"), .text("Cleo")]])
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = try restoredTab(objectType: .materializedView, isView: false)
        defer { coordinator.teardown() }

        coordinator.addNewRow()
        coordinator.duplicateSelectedRow(index: 0)
        coordinator.pasteRows()
        #expect(try rowCount(coordinator) == 2)

        coordinator.deleteSelectedRows(indices: [0])
        #expect(!coordinator.changeManager.hasChanges)
    }

    @Test("Delete stages nothing on a view whose load marked it editable")
    func deleteRefusesALoadedView() throws {
        let coordinator = try restoredTab(objectType: .view, isView: true)
        defer { coordinator.teardown() }

        coordinator.deleteSelectedRows(indices: [0])
        #expect(!coordinator.changeManager.hasChanges)
    }

    @Test("Add, Duplicate and Paste still stage rows on a table")
    func rowCommandsStillWorkOnATable() throws {
        let clipboard = MaterializedViewClipboard()
        clipboard.gridRows = GridRowsClipboardPayload(columns: ["id", "name"], rows: [[.text("3"), .text("Cleo")]])
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = try restoredTab(objectType: .table, isView: false)
        defer { coordinator.teardown() }

        coordinator.addNewRow()
        #expect(try rowCount(coordinator) == 3)
        coordinator.duplicateSelectedRow(index: 0)
        #expect(try rowCount(coordinator) == 4)
        coordinator.pasteRows()
        #expect(try rowCount(coordinator) == 5)
    }

    @Test("Delete still stages on a table")
    func deleteStillStagesOnATable() throws {
        let coordinator = try restoredTab(objectType: .table, isView: false)
        defer { coordinator.teardown() }

        coordinator.deleteSelectedRows(indices: [0])
        #expect(coordinator.changeManager.hasChanges)
    }

    // MARK: - The grid's empty-space menu

    @Test("The grid's empty space offers Add Row on a table and not on a materialized view")
    func emptySpaceMenuFollowsTheGate() throws {
        let matview = try restoredTab(objectType: .materializedView, isView: false)
        defer { matview.teardown() }
        let table = try restoredTab(objectType: .table, isView: false)
        defer { table.teardown() }

        let matviewDelegate = DataTabGridDelegate()
        matviewDelegate.coordinator = matview
        matviewDelegate.onAddRow = { matview.addNewRow() }
        let tableDelegate = DataTabGridDelegate()
        tableDelegate.coordinator = table
        tableDelegate.onAddRow = { table.addNewRow() }

        #expect(matviewDelegate.dataGridEmptySpaceMenu() == nil)
        #expect(tableDelegate.dataGridEmptySpaceMenu() != nil)
    }
}
