//
//  TableViewCoordinatorLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class FakeColumnLayoutPersister: ColumnLayoutPersisting {
    var stored: [String: ColumnLayoutState] = [:]

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? {
        stored[key.tableName]
    }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {
        stored[key.tableName] = layout
    }

    func clear(for key: ColumnLayoutTableKey) {
        stored.removeValue(forKey: key.tableName)
    }
}

@Suite("TableViewCoordinator.savedColumnLayout")
@MainActor
struct TableViewCoordinatorLayoutTests {
    private func makeCoordinator(
        tabType: TabType?,
        connectionId: UUID?,
        tableName: String?,
        persister: ColumnLayoutPersisting
    ) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: persister
        )
        coordinator.tabType = tabType
        coordinator.connectionId = connectionId
        coordinator.tableName = tableName
        return coordinator
    }

    private func nonEmptyLayout() -> ColumnLayoutState {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60]
        return layout
    }

    private func attachColumns(
        _ widths: [String: CGFloat],
        tableRows: TableRows,
        to coordinator: TableViewCoordinator
    ) -> [String: NSTableColumn] {
        let tableView = NSTableView()
        coordinator.tableView = tableView
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)

        var result: [String: NSTableColumn] = [:]
        for (index, name) in tableRows.columns.enumerated() {
            let identifier = coordinator.columnIdentifier(for: index) ?? ColumnIdentitySchema.slotIdentifier(index)
            let column = NSTableColumn(identifier: identifier)
            column.width = widths[name] ?? 100
            tableView.addTableColumn(column)
            result[name] = column
        }
        coordinator.updateColumnPresentations(from: tableRows)
        return result
    }

    @Test("Table tab returns persisted layout when present, ignoring binding")
    func tableTabPrefersPersister() {
        let persister = FakeColumnLayoutPersister()
        let stored = nonEmptyLayout()
        persister.stored["users"] = stored
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: persister
        )

        var binding = ColumnLayoutState()
        binding.columnWidths = ["other": 999]

        let resolved = coordinator.savedColumnLayout(binding: binding)
        #expect(resolved?.columnWidths == ["id": 60])
    }

    @Test("Table tab falls back to binding when persister has nothing")
    func tableTabFallsBackToBinding() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        let resolved = coordinator.savedColumnLayout(binding: nonEmptyLayout())
        #expect(resolved?.columnWidths == ["id": 60])
    }

    @Test("Table tab returns nil when both persister and binding are empty")
    func tableTabBothEmptyReturnsNil() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        #expect(coordinator.savedColumnLayout(binding: ColumnLayoutState()) == nil)
    }

    @Test("Query tab drops a stale saved column order so new columns keep their query position")
    func queryTabDropsStaleColumnOrder() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        var binding = ColumnLayoutState()
        binding.columnWidths = ["id": 60, "business_model": 120]
        binding.columnOrder = ["id", "business_model"]

        var expected = ColumnLayoutState()
        expected.columnWidths = ["id": 60, "business_model": 120]

        #expect(coordinator.savedColumnLayout(binding: binding) == expected)
    }

    @Test("Query tab keeps remembered widths when there is no saved order")
    func queryTabKeepsWidths() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )

        var expected = ColumnLayoutState()
        expected.columnWidths = ["id": 60]

        #expect(coordinator.savedColumnLayout(binding: nonEmptyLayout()) == expected)
    }

    @Test("Query tab returns nil when binding is empty")
    func queryTabEmptyReturnsNil() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        #expect(coordinator.savedColumnLayout(binding: ColumnLayoutState()) == nil)
    }

    @Test("Table tab without connectionId or tableName falls back to binding")
    func tableTabMissingIdentitySkipsPersister() {
        let persister = FakeColumnLayoutPersister()
        persister.stored["users"] = nonEmptyLayout()
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: nil,
            tableName: nil,
            persister: persister
        )

        var binding = ColumnLayoutState()
        binding.columnWidths = ["fallback": 42]

        let resolved = coordinator.savedColumnLayout(binding: binding)
        #expect(resolved?.columnWidths == ["fallback": 42])
    }

    @Test("resolvedColumnLayout merges live widths on top of a saved layout")
    func resolvedMergesLiveWidthsOntoSaved() {
        let persister = FakeColumnLayoutPersister()
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 60, "name": 100]
        persister.stored["users"] = saved
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: persister
        )

        let resolved = coordinator.resolvedColumnLayout(
            binding: ColumnLayoutState(),
            liveWidths: ["name": 250]
        )
        #expect(resolved?.columnWidths == ["id": 60, "name": 250])
    }

    @Test("resolvedColumnLayout preserves an unpersisted user width")
    func resolvedPreservesUnpersistedUserWidth() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        #expect(
            coordinator.resolvedColumnLayout(
                binding: ColumnLayoutState(),
                liveWidths: ["name": 250]
            )?.columnWidths == ["name": 250]
        )
    }

    @Test("Live widths are kept on a same-table reload but discarded on a table switch")
    func liveWidthsGatedByTableIdentity() {
        let connectionId = UUID()
        let tableA = ColumnLayoutTableKey(connectionId: connectionId, databaseName: "db", schemaName: "public", tableName: "a")
        let tableB = ColumnLayoutTableKey(connectionId: connectionId, databaseName: "db", schemaName: "public", tableName: "b")
        let live: [String: CGFloat] = ["id": 120, "name": 240]

        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: tableA, current: tableA, liveWidths: live) == live)
        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: tableA, current: tableB, liveWidths: live).isEmpty)
        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: nil, current: tableA, liveWidths: live).isEmpty)
        #expect(TableViewCoordinator.liveWidthsForSameTable(previous: nil, current: nil, liveWidths: live) == live)
    }

    @Test("Captured layouts contain only user-sized widths")
    func captureContainsOnlyUserSizedWidths() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("Ada")]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        _ = attachColumns(["id": 75, "name": 140], tableRows: rows, to: coordinator)
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 75]
        coordinator.synchronizeUserSizedColumns(
            with: saved,
            columns: rows.columns,
            tableIdentityChanged: true
        )

        let captured = try #require(coordinator.captureColumnLayout())

        #expect(captured.columnWidths == ["id": 75])
        #expect(captured.columnContentWidths == ["id": 75])
        #expect(captured.columnOrder == ["id", "name"])
    }

    @Test("Stored layouts keep legacy total widths and materialize content widths")
    func storedWidthsRepresentContentWidth() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "events",
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("2026-08-17")]],
            columns: ["created_at"],
            columnTypes: [.date(rawType: "DATE")]
        )
        let columns = attachColumns(["created_at": 176], tableRows: rows, to: coordinator)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["created_at": 160]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: rows.columns,
            tableIdentityChanged: true
        )

        let captured = try #require(coordinator.captureColumnLayout())
        let materialized = try #require(coordinator.materializedColumnLayout(stored, tableRows: rows))

        #expect(columns["created_at"]?.width == 176)
        #expect(captured.columnWidths == ["created_at": 176])
        #expect(captured.columnContentWidths == ["created_at": 160])
        #expect(materialized.columnWidths == ["created_at": 176])
    }

    @Test("Content widths fall back per column for partial and content-only layouts")
    func contentWidthsUsePerColumnFallback() throws {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("a"), .text("b"), .text("c")]],
            columns: ["a", "b", "c"],
            columnTypes: [
                .date(rawType: "DATE"),
                .date(rawType: "DATE"),
                .date(rawType: "DATE"),
            ]
        )
        coordinator.rebuildColumnMetadataCache(from: rows)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["a": 160, "b": 170]
        stored.columnContentWidths = ["a": 150, "c": 180]

        let materialized = try #require(coordinator.materializedColumnLayout(stored, tableRows: rows))

        #expect(materialized.columnWidths == ["a": 166, "b": 186, "c": 196])

        var contentOnly = ColumnLayoutState()
        contentOnly.columnContentWidths = ["c": 180]
        #expect(coordinator.savedColumnLayout(binding: contentOnly) != nil)
    }

    @Test("Duplicate column names reserve accessory width once and round-trip without growth")
    func duplicateNamesReserveAccessoryWidthOnce() throws {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("value"), .text("2026-08-17")]],
            columns: ["result", "result"],
            columnTypes: [.text(rawType: "TEXT"), .date(rawType: "DATE")]
        )
        _ = attachColumns(["result": 176], tableRows: rows, to: coordinator)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["result": 160]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: rows.columns,
            tableIdentityChanged: true
        )

        let materialized = try #require(coordinator.materializedColumnLayout(stored, tableRows: rows))
        let captured = try #require(coordinator.captureColumnLayout())
        let restored = try #require(coordinator.materializedColumnLayout(captured, tableRows: rows))

        #expect(materialized.columnWidths == ["result": 176])
        #expect(captured.columnWidths == ["result": 176])
        #expect(captured.columnContentWidths == ["result": 160])
        #expect(restored.columnWidths == ["result": 176])
    }

    @Test("Mixed duplicate actions use one maximum reservation and round-trip")
    func mixedDuplicateActionsReserveWidthOnce() throws {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        var rows = TableRows.from(
            queryRows: [[.text("1"), .text("2")]],
            columns: ["parent_id", "parent_id"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        _ = rows.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])
        coordinator.dropdownColumns = [0]
        _ = attachColumns(["parent_id": 180], tableRows: rows, to: coordinator)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["parent_id": 160]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: rows.columns,
            tableIdentityChanged: true
        )

        let materialized = try #require(coordinator.materializedColumnLayout(stored, tableRows: rows))
        let captured = try #require(coordinator.captureColumnLayout())
        let restored = try #require(coordinator.materializedColumnLayout(captured, tableRows: rows))

        #expect(coordinator.columnPresentation(for: 0, in: rows).accessory == .chevron)
        #expect(coordinator.columnPresentation(for: 1, in: rows).accessory == .foreignKey)
        #expect(materialized.columnWidths == ["parent_id": 180])
        #expect(captured.columnWidths == ["parent_id": 180])
        #expect(captured.columnContentWidths == ["parent_id": 160])
        #expect(restored.columnWidths == ["parent_id": 180])
    }

    @Test("Untouched automatic widths stay out of captured layouts")
    func automaticWidthsStayOutOfCapturedLayouts() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        _ = attachColumns(["name": 140], tableRows: rows, to: coordinator)
        coordinator.synchronizeUserSizedColumns(
            with: nil,
            columns: rows.columns,
            tableIdentityChanged: true
        )

        let captured = try #require(coordinator.captureColumnLayout())

        #expect(captured.columnWidths.isEmpty)
        #expect(captured.columnOrder == ["name"])
    }

    @Test("A resize notification takes ownership unless the width change is automatic")
    func resizeNotificationTakesOwnership() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        defer { coordinator.layoutPersistTask?.cancel() }
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let columns = attachColumns(["name": 140], tableRows: rows, to: coordinator)
        let column = try #require(columns["name"])
        let notification = Notification(
            name: NSTableView.columnDidResizeNotification,
            object: coordinator.tableView,
            userInfo: ["NSTableColumn": column, "NSOldWidth": CGFloat(100)]
        )

        coordinator.isApplyingAutomaticColumnWidths = true
        coordinator.tableViewColumnDidResize(notification)
        #expect(coordinator.userSizedColumnNames.isEmpty)

        coordinator.isApplyingAutomaticColumnWidths = false
        coordinator.tableViewColumnDidResize(notification)
        #expect(coordinator.userSizedColumnNames == ["name"])
    }

    @Test("A row-number resize never creates or persists a user layout")
    func rowNumberResizeIsIgnored() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        _ = attachColumns(["name": 140], tableRows: rows, to: coordinator)
        let tableView = try #require(coordinator.tableView)
        let rowNumberColumn = DataGridView.makeRowNumberColumn()
        tableView.addTableColumn(rowNumberColumn)
        let notification = Notification(
            name: NSTableView.columnDidResizeNotification,
            object: tableView,
            userInfo: ["NSTableColumn": rowNumberColumn, "NSOldWidth": CGFloat(40)]
        )

        coordinator.tableViewColumnDidResize(notification)

        #expect(coordinator.userSizedColumnNames.isEmpty)
        #expect(coordinator.pendingColumnLayoutPersistence == nil)
        #expect(coordinator.layoutPersistTask == nil)
    }

    @Test("Switching tables flushes a pending resize to the outgoing table")
    func tableSwitchFlushesOutgoingResize() throws {
        let persister = FakeColumnLayoutPersister()
        let connectionId = UUID()
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: connectionId,
            tableName: "users",
            persister: persister
        )
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let columns = attachColumns(["name": 180], tableRows: rows, to: coordinator)
        let column = try #require(columns["name"])
        #expect(coordinator.markColumnWidthUserSized(column))
        coordinator.scheduleLayoutPersist()

        var nextConfiguration = DataGridConfiguration()
        nextConfiguration.connectionId = connectionId
        nextConfiguration.databaseName = "db"
        nextConfiguration.tableName = "projects"
        nextConfiguration.tabType = .table
        coordinator.apply(configuration: nextConfiguration, isEditable: true)

        #expect(persister.stored["users"]?.columnWidths == ["name": 180])
        #expect(persister.stored["users"]?.columnContentWidths == ["name": 180])
        #expect(persister.stored["projects"] == nil)
        #expect(coordinator.pendingColumnLayoutPersistence == nil)
        #expect(coordinator.layoutPersistTask == nil)
    }

    @Test("A pending resize snapshot tracks a late accessory without changing content width")
    func pendingResizeTracksLateAccessory() throws {
        let persister = FakeColumnLayoutPersister()
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "nodes",
            persister: persister
        )
        var rows = TableRows.from(
            queryRows: [[.text("1")]],
            columns: ["parent_id"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let columns = attachColumns(["parent_id": 160], tableRows: rows, to: coordinator)
        coordinator.tableRowsProvider = { rows }
        let column = try #require(columns["parent_id"])
        #expect(coordinator.markColumnWidthUserSized(column))
        coordinator.scheduleLayoutPersist()
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == ["parent_id": 160])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == ["parent_id": 160])
        _ = rows.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])

        coordinator.refreshCellPresentations()

        #expect(column.width == 180)
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == ["parent_id": 180])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == ["parent_id": 160])

        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persister.stored["nodes"]?.columnWidths == ["parent_id": 180])
        #expect(persister.stored["nodes"]?.columnContentWidths == ["parent_id": 160])
    }

    @Test("A pending resize snapshot tracks structural presentation changes")
    func pendingResizeTracksStructuralPresentationChange() throws {
        let persister = FakeColumnLayoutPersister()
        let connectionId = UUID()
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: connectionId,
            tableName: "events",
            persister: persister
        )
        let rows = TableRows.from(
            queryRows: [[.text("2026-08-17")]],
            columns: ["created_at"],
            columnTypes: [.date(rawType: "DATE")]
        )
        let columns = attachColumns(["created_at": 176], tableRows: rows, to: coordinator)
        coordinator.tableRowsProvider = { rows }
        let column = try #require(columns["created_at"])
        #expect(coordinator.markColumnWidthUserSized(column))
        coordinator.scheduleLayoutPersist()

        var configuration = DataGridConfiguration()
        configuration.connectionId = connectionId
        configuration.tableName = "events"
        configuration.tabType = .table
        coordinator.apply(configuration: configuration, isEditable: false)
        let changes = coordinator.updateColumnPresentations(from: rows)
        let reconciled = coordinator.liveWidthsForReconciliation(
            ["created_at": column.width],
            presentationChanges: changes,
            columns: rows.columns
        )
        column.width = try #require(reconciled["created_at"])
        coordinator.refreshPendingLayoutAfterPresentationChanges(changes, tableRows: rows)

        #expect(column.width == 160)
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == ["created_at": 160])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == ["created_at": 160])

        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persister.stored["events"]?.columnWidths == ["created_at": 160])
        #expect(persister.stored["events"]?.columnContentWidths == ["created_at": 160])
    }

    @Test("A query-grid presentation change keeps legacy and content widths synchronized")
    func queryPresentationChangeRefreshesPendingLayout() throws {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let plainRows = TableRows.from(
            queryRows: [[.text("value")]],
            columns: ["result"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let dateRows = TableRows.from(
            queryRows: [[.text("2026-08-17")]],
            columns: ["result"],
            columnTypes: [.date(rawType: "DATE")]
        )
        let columns = attachColumns(["result": 160], tableRows: plainRows, to: coordinator)
        coordinator.tableRowsProvider = { plainRows }
        let column = try #require(columns["result"])
        #expect(coordinator.markColumnWidthUserSized(column))
        var persistedLayout: ColumnLayoutState?
        coordinator.onColumnLayoutDidChange = { persistedLayout = $0 }
        coordinator.scheduleLayoutPersist()

        coordinator.rebuildColumnMetadataCache(from: dateRows)
        let changes = coordinator.updateColumnPresentations(from: dateRows)
        column.width = 176
        coordinator.tableRowsProvider = { dateRows }
        coordinator.refreshPendingLayoutAfterPresentationChanges(changes, tableRows: dateRows)

        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == ["result": 176])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == ["result": 160])

        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persistedLayout?.columnWidths == ["result": 176])
        #expect(persistedLayout?.columnContentWidths == ["result": 160])
    }

    @Test("Divider fit takes ownership even when AppKit does not change the width")
    func dividerFitTakesOwnership() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        defer { coordinator.layoutPersistTask?.cancel() }
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        _ = attachColumns(["name": 100], tableRows: rows, to: coordinator)
        coordinator.synchronizeUserSizedColumns(
            with: nil,
            columns: rows.columns,
            tableIdentityChanged: true
        )
        let tableView = try #require(coordinator.tableView)

        _ = coordinator.tableView(tableView, sizeToFitWidthOfColumn: 0)

        #expect(coordinator.userSizedColumnNames == ["name"])
    }

    @Test("Divider fit forwards each column's resolved action footprint")
    func dividerFitUsesResolvedAccessory() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "events",
            persister: FakeColumnLayoutPersister()
        )
        defer { coordinator.resetColumnWidthOwnership() }
        let value = String(repeating: "M", count: 20)
        let rows = TableRows.from(
            queryRows: [[.text(value), .text(value), .text(value)]],
            columns: ["plain", "created_at", "parent_id"],
            columnTypes: [
                .text(rawType: "TEXT"),
                .date(rawType: "DATE"),
                .text(rawType: "TEXT"),
            ],
            columnForeignKeys: [
                "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
            ],
            foreignKeysFetched: true
        )
        _ = attachColumns([:], tableRows: rows, to: coordinator)
        let tableView = try #require(coordinator.tableView)

        let plain = coordinator.tableView(tableView, sizeToFitWidthOfColumn: 0)
        let date = coordinator.tableView(tableView, sizeToFitWidthOfColumn: 1)
        let foreignKey = coordinator.tableView(tableView, sizeToFitWidthOfColumn: 2)

        #expect(date == plain + 16)
        #expect(foreignKey == plain + 20)
    }

    @Test("Reset returns saved columns to automatic ownership")
    func resetReturnsColumnsToAutomaticOwnership() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        var saved = ColumnLayoutState()
        saved.columnWidths = ["name": 240]
        coordinator.synchronizeUserSizedColumns(
            with: saved,
            columns: ["name"],
            tableIdentityChanged: true
        )

        coordinator.resetColumnWidthOwnership()

        #expect(coordinator.userSizedColumnNames.isEmpty)
    }

    @Test("Reconciliation preserves stable automatic widths and invalidates only changed presentations")
    func reconciliationInvalidatesOnlyChangedAutomaticWidths() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 75]
        coordinator.synchronizeUserSizedColumns(
            with: saved,
            columns: ["id", "name"],
            tableIdentityChanged: true
        )
        let liveWidths: [String: CGFloat] = ["id": 75, "name": 140]
        var presentationChanges = DataGridColumnPresentationChanges()
        presentationChanges.indices = IndexSet([0, 1])
        presentationChanges.widthDeltas = [0: 8, 1: 8]

        let stable = coordinator.liveWidthsForReconciliation(
            liveWidths,
            presentationChanges: DataGridColumnPresentationChanges(),
            columns: ["id", "name"]
        )
        let presentationChanged = coordinator.liveWidthsForReconciliation(
            liveWidths,
            presentationChanges: presentationChanges,
            columns: ["id", "name"]
        )

        #expect(stable == liveWidths)
        #expect(presentationChanged == ["id": 83])
    }

    @Test("Reordering columns does not invent accessory width changes")
    func reorderedColumnsKeepPresentationIdentity() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "events",
            persister: FakeColumnLayoutPersister()
        )
        let original = TableRows.from(
            queryRows: [[.text("1"), .text("2026-08-17")]],
            columns: ["id", "created_at"],
            columnTypes: [.text(rawType: "TEXT"), .date(rawType: "DATE")]
        )
        let reordered = TableRows.from(
            queryRows: [[.text("2026-08-17"), .text("1")]],
            columns: ["created_at", "id"],
            columnTypes: [.date(rawType: "DATE"), .text(rawType: "TEXT")]
        )
        coordinator.rebuildColumnMetadataCache(from: original)
        _ = coordinator.updateColumnPresentations(from: original)
        coordinator.rebuildColumnMetadataCache(from: reordered)

        let changes = coordinator.updateColumnPresentations(from: reordered)

        #expect(changes.isEmpty)
    }

    @Test("Duplicate presentation transitions adjust a shared live width once")
    func duplicatePresentationTransitionAdjustsWidthOnce() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        var rows = TableRows.from(
            queryRows: [[.text("open"), .text("closed")]],
            columns: ["status", "status"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        coordinator.rebuildColumnMetadataCache(from: rows)
        _ = coordinator.updateColumnPresentations(from: rows)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["status": 160]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: rows.columns,
            tableIdentityChanged: true
        )
        _ = rows.updateDisplayMetadata(columnEnumValues: ["status": ["open", "closed"]])
        coordinator.rebuildColumnMetadataCache(from: rows)

        let changes = coordinator.updateColumnPresentations(from: rows)
        let reconciled = coordinator.liveWidthsForReconciliation(
            ["status": 160],
            presentationChanges: changes,
            columns: rows.columns
        )
        coordinator.refreshPendingLayoutAfterPresentationChanges(changes, tableRows: rows)

        #expect(changes.widthDeltasByName == ["status": 16])
        #expect(reconciled == ["status": 176])
        #expect(coordinator.pendingColumnLayoutPersistence == nil)
    }

    @Test("A duplicate slot change does not resize while the shared maximum is unchanged")
    func duplicateSlotChangeKeepsSharedMaximumWidth() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let original = TableRows.from(
            queryRows: [[.text("2026-08-17"), .text("2026-08-18")]],
            columns: ["date", "date"],
            columnTypes: [.date(rawType: "DATE"), .date(rawType: "DATE")]
        )
        let changed = TableRows.from(
            queryRows: [[.text("plain"), .text("2026-08-18")]],
            columns: ["date", "date"],
            columnTypes: [.text(rawType: "TEXT"), .date(rawType: "DATE")]
        )
        coordinator.rebuildColumnMetadataCache(from: original)
        _ = coordinator.updateColumnPresentations(from: original)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["date": 176]
        stored.columnContentWidths = ["date": 160]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: original.columns,
            tableIdentityChanged: true
        )
        coordinator.rebuildColumnMetadataCache(from: changed)

        let changes = coordinator.updateColumnPresentations(from: changed)
        let reconciled = coordinator.liveWidthsForReconciliation(
            ["date": 176],
            presentationChanges: changes,
            columns: changed.columns
        )

        #expect(changes.indices == IndexSet(integer: 0))
        #expect(changes.widthDeltasByName == ["date": 0])
        #expect(reconciled == ["date": 176])
    }

    @Test("Adding and removing a max-reservation duplicate adjusts the group once")
    func duplicateMaximumReservationAdditionAndRemoval() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let plain = TableRows.from(
            queryRows: [[.text("plain")]],
            columns: ["value"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let withDateDuplicate = TableRows.from(
            queryRows: [[.text("plain"), .text("2026-08-17")]],
            columns: ["value", "value"],
            columnTypes: [.text(rawType: "TEXT"), .date(rawType: "DATE")]
        )
        coordinator.rebuildColumnMetadataCache(from: plain)
        _ = coordinator.updateColumnPresentations(from: plain)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["value": 160]
        stored.columnContentWidths = ["value": 160]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: plain.columns,
            tableIdentityChanged: true
        )

        coordinator.rebuildColumnMetadataCache(from: withDateDuplicate)
        let added = coordinator.updateColumnPresentations(from: withDateDuplicate)
        let expanded = coordinator.liveWidthsForReconciliation(
            ["value": 160],
            presentationChanges: added,
            columns: withDateDuplicate.columns
        )

        coordinator.rebuildColumnMetadataCache(from: plain)
        let removed = coordinator.updateColumnPresentations(from: plain)
        let contracted = coordinator.liveWidthsForReconciliation(
            expanded,
            presentationChanges: removed,
            columns: plain.columns
        )

        #expect(added.widthDeltasByName == ["value": 16])
        #expect(expanded == ["value": 176])
        #expect(removed.indices == IndexSet(integer: 0))
        #expect(removed.widthDeltasByName == ["value": -16])
        #expect(contracted == ["value": 160])
    }

    @Test("Reset invalidates every automatic live width once")
    func resetInvalidatesAutomaticLiveWidthsOnce() {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: FakeColumnLayoutPersister()
        )
        let liveWidths: [String: CGFloat] = ["id": 75, "name": 140]

        coordinator.resetColumnWidthOwnership()
        let afterReset = coordinator.liveWidthsForReconciliation(
            liveWidths,
            presentationChanges: DataGridColumnPresentationChanges(),
            columns: ["id", "name"]
        )
        let nextUpdate = coordinator.liveWidthsForReconciliation(
            liveWidths,
            presentationChanges: DataGridColumnPresentationChanges(),
            columns: ["id", "name"]
        )

        #expect(afterReset.isEmpty)
        #expect(nextUpdate == liveWidths)
    }

    @Test("Reset cancels a pending width write")
    func resetCancelsPendingWidthWrite() throws {
        let persister = FakeColumnLayoutPersister()
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "users",
            persister: persister
        )
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let columns = attachColumns(["name": 180], tableRows: rows, to: coordinator)
        let column = try #require(columns["name"])
        #expect(coordinator.markColumnWidthUserSized(column))
        coordinator.scheduleLayoutPersist()

        coordinator.resetColumnWidthOwnership()
        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persister.stored["users"] == nil)
        #expect(coordinator.userSizedColumnNames.isEmpty)
        #expect(coordinator.pendingColumnLayoutPersistence == nil)
        #expect(coordinator.layoutPersistTask == nil)
    }

    @Test("Late accessory metadata recalculates automatic widths and preserves user content width")
    func lateAccessoryMetadataPreservesContentWidth() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "nodes",
            persister: FakeColumnLayoutPersister()
        )
        let value = String(repeating: "M", count: 20)
        var rows = TableRows.from(
            queryRows: [[.text(value), .text(value)]],
            columns: ["id", "parent_id"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        coordinator.tableRowsProvider = { rows }
        let columns = attachColumns(["id": 75, "parent_id": 100], tableRows: rows, to: coordinator)
        coordinator.tableRowsProvider = { rows }
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 75]
        coordinator.synchronizeUserSizedColumns(
            with: saved,
            columns: rows.columns,
            tableIdentityChanged: true
        )
        _ = rows.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])

        coordinator.refreshCellPresentations()

        let idColumn = try #require(columns["id"])
        let parentColumn = try #require(columns["parent_id"])
        let expected = coordinator.cellFactory.calculateOptimalColumnWidth(
            for: "parent_id",
            columnIndex: 1,
            tableRows: rows,
            accessory: .foreignKey
        )
        #expect(idColumn.width == 75)
        #expect(parentColumn.width == expected)
        #expect(coordinator.userSizedColumnNames == ["id"])

        _ = rows.updateDisplayMetadata(columnForeignKeys: [:])
        coordinator.refreshCellPresentations()
        let plainExpected = coordinator.cellFactory.calculateOptimalColumnWidth(
            for: "parent_id",
            columnIndex: 1,
            tableRows: rows
        )
        #expect(parentColumn.width == plainExpected)

        _ = rows.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])
        coordinator.refreshCellPresentations()
        #expect(parentColumn.width == expected)

        saved.columnWidths["parent_id"] = 228
        coordinator.synchronizeUserSizedColumns(
            with: saved,
            columns: rows.columns,
            tableIdentityChanged: false
        )
        parentColumn.width = 240
        _ = rows.updateDisplayMetadata(columnForeignKeys: [:])
        coordinator.refreshCellPresentations()

        #expect(parentColumn.width == 220)
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == [
            "id": 75,
            "parent_id": 220,
        ])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == [
            "id": 75,
            "parent_id": 220,
        ])
        coordinator.flushPendingColumnLayoutPersistence()
    }

    @Test("Late enum metadata resizes an automatic column without foreign keys")
    func lateEnumMetadataResizesAutomaticColumn() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "tasks",
            persister: FakeColumnLayoutPersister()
        )
        let value = String(repeating: "M", count: 20)
        var rows = TableRows.from(
            queryRows: [[.text(value)]],
            columns: ["status"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let columns = attachColumns(["status": 100], tableRows: rows, to: coordinator)
        coordinator.tableRowsProvider = { rows }
        coordinator.synchronizeUserSizedColumns(
            with: nil,
            columns: rows.columns,
            tableIdentityChanged: true
        )
        _ = rows.updateDisplayMetadata(columnEnumValues: ["status": ["open", "closed"]])

        coordinator.refreshCellPresentations()

        let column = try #require(columns["status"])
        let expected = coordinator.cellFactory.calculateOptimalColumnWidth(
            for: "status",
            columnIndex: 0,
            tableRows: rows,
            accessory: .chevron
        )
        #expect(column.width == expected)
        #expect(coordinator.columnPresentation(for: 0, in: rows).kind == .dropdown)

        _ = rows.updateDisplayMetadata(columnEnumValues: [:])
        coordinator.refreshCellPresentations()

        let plainExpected = coordinator.cellFactory.calculateOptimalColumnWidth(
            for: "status",
            columnIndex: 0,
            tableRows: rows
        )
        #expect(column.width == plainExpected)
        #expect(coordinator.columnPresentation(for: 0, in: rows).kind == .text)
    }

    @Test("Late metadata waits for an active cell overlay before resizing")
    func lateMetadataWaitsForActiveOverlay() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "nodes",
            persister: FakeColumnLayoutPersister()
        )
        let value = String(repeating: "M", count: 20)
        var rows = TableRows.from(
            queryRows: [[.text(value)]],
            columns: ["parent_id"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let columns = attachColumns(["parent_id": 100], tableRows: rows, to: coordinator)
        coordinator.tableRowsProvider = { rows }
        coordinator.synchronizeUserSizedColumns(
            with: nil,
            columns: rows.columns,
            tableIdentityChanged: true
        )
        let tableView = try #require(coordinator.tableView)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.updateCache()
        tableView.reloadData()
        let column = try #require(columns["parent_id"])
        let originalWidth = column.width
        let editor = CellOverlayEditor()
        editor.onRemove = { [weak coordinator] in
            coordinator?.flushPendingCellPresentationRefresh()
        }
        coordinator.overlayEditor = editor
        editor.install(
            in: tableView,
            row: 0,
            column: 0,
            columnIndex: 0,
            container: CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        )
        _ = rows.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])

        coordinator.refreshCellPresentations()

        #expect(editor.isActive)
        #expect(coordinator.pendingCellPresentationRefresh)
        #expect(column.width == originalWidth)

        editor.removeOverlay()

        let expected = coordinator.cellFactory.calculateOptimalColumnWidth(
            for: "parent_id",
            columnIndex: 0,
            tableRows: rows,
            accessory: .foreignKey
        )
        #expect(!editor.isActive)
        #expect(!coordinator.pendingCellPresentationRefresh)
        #expect(column.width == expected)
        #expect(coordinator.userSizedColumnNames.isEmpty)
    }
}
