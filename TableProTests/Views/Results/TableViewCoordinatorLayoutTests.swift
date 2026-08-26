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
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("direct"), .text("EU")]],
            columns: ["id", "business_model", "region"],
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: 3)
        )
        coordinator.rebuildColumnMetadataCache(from: rows)
        var binding = ColumnLayoutState()
        binding.columnWidths = ["id": 60, "business_model": 120]
        binding.columnOrder = ["id", "business_model"]

        var expected = ColumnLayoutState()
        expected.columnWidths = ["id": 60, "business_model": 120]

        #expect(coordinator.savedColumnLayout(binding: binding) == expected)
    }

    /// The order is dropped because the columns moved under it, not because the grid has no table.
    /// A re-run of the same query, and every update of the Structure grid, arrives with the same
    /// column set, and the reorder the user made has to survive it.
    @Test("Query tab keeps a column order saved for the same columns")
    func queryTabKeepsMatchingColumnOrder() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("direct")]],
            columns: ["id", "business_model"],
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: 2)
        )
        coordinator.rebuildColumnMetadataCache(from: rows)
        var binding = ColumnLayoutState()
        binding.columnWidths = ["id": 60, "business_model": 120]
        binding.columnOrder = ["business_model", "id"]

        #expect(coordinator.savedColumnLayout(binding: binding) == binding)
    }

    /// A saved order names its columns, and `SELECT a.id, b.id` gives two of them the same name.
    /// `ColumnIdentitySchema` resolves a duplicate to its last slot, so replaying such an order
    /// silently swaps the pair.
    @Test("Query tab drops a column order when two columns share a name")
    func queryTabDropsColumnOrderForDuplicateNames() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("2")]],
            columns: ["id", "id"],
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: 2)
        )
        coordinator.rebuildColumnMetadataCache(from: rows)
        var binding = ColumnLayoutState()
        binding.columnWidths = ["id": 60]
        binding.columnOrder = ["id", "id"]

        var expected = ColumnLayoutState()
        expected.columnWidths = ["id": 60]

        #expect(coordinator.savedColumnLayout(binding: binding) == expected)
    }

    /// A reorder with no width change is the whole layout, and it used to fall through the
    /// emptiness guard and come back as nil.
    @Test("Query tab keeps an order-only layout")
    func queryTabKeepsAnOrderOnlyLayout() {
        let coordinator = makeCoordinator(
            tabType: .query,
            connectionId: nil,
            tableName: nil,
            persister: FakeColumnLayoutPersister()
        )
        let rows = TableRows.from(
            queryRows: [[.text("1"), .text("direct")]],
            columns: ["id", "business_model"],
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: 2)
        )
        coordinator.rebuildColumnMetadataCache(from: rows)
        var binding = ColumnLayoutState()
        binding.columnOrder = ["business_model", "id"]

        #expect(coordinator.savedColumnLayout(binding: binding) == binding)
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

    /// The width a column had is the width it gets back. Deriving it from the accessory instead
    /// would resize the column across sessions in exactly the cases the accessory arrives late,
    /// which is the whole problem this area exists to avoid.
    @Test("A captured width round-trips unchanged while an accessory is showing")
    func capturedWidthRoundTripsWithAccessory() throws {
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
        let resolved = try #require(coordinator.resolvedColumnLayout(binding: captured, liveWidths: [:]))

        #expect(coordinator.columnPresentation(for: 0, in: rows).accessory == .chevron)
        #expect(columns["created_at"]?.width == 176)
        #expect(captured.columnWidths == ["created_at": 176])
        #expect(captured.columnContentWidths == ["created_at": 176])
        #expect(resolved.columnWidths == ["created_at": 176])
    }

    /// The drift this guards against: a width saved while the arrow was showing, restored on an
    /// open where the arrow is not known yet. Re-deriving the width from the current accessory
    /// state returned it 20pt narrower and the next save recorded the smaller number, so a column
    /// shrank on every visit until the metadata happened to be ready in time.
    @Test("A width saved with an accessory restores unchanged before the accessory is known")
    func capturedWidthRoundTripsWithoutAccessory() throws {
        let coordinator = makeCoordinator(
            tabType: .table,
            connectionId: UUID(),
            tableName: "nodes",
            persister: FakeColumnLayoutPersister()
        )
        var withForeignKey = TableRows.from(
            queryRows: [[.text("1")]],
            columns: ["parent_id"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        _ = withForeignKey.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])
        let columns = attachColumns(["parent_id": 200], tableRows: withForeignKey, to: coordinator)
        var stored = ColumnLayoutState()
        stored.columnWidths = ["parent_id": 200]
        coordinator.synchronizeUserSizedColumns(
            with: stored,
            columns: withForeignKey.columns,
            tableIdentityChanged: true
        )

        let captured = try #require(coordinator.captureColumnLayout())

        let plain = TableRows.from(
            queryRows: [[.text("1")]],
            columns: ["parent_id"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        coordinator.tableRowsProvider = { plain }
        coordinator.rebuildColumnMetadataCache(from: plain)
        _ = coordinator.updateColumnPresentations(from: plain)
        let restored = try #require(coordinator.resolvedColumnLayout(binding: captured, liveWidths: [:]))

        #expect(columns["parent_id"]?.width == 200)
        #expect(captured.columnWidths == ["parent_id": 200])
        #expect(coordinator.columnPresentation(for: 0, in: plain).accessory == .none)
        #expect(restored.columnWidths == ["parent_id": 200])
    }

    @Test("A content-only layout still counts as a saved layout")
    func contentOnlyLayoutCountsAsSaved() throws {
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

        #expect(coordinator.savedColumnLayout(binding: stored)?.columnWidths == ["a": 160, "b": 170])

        var contentOnly = ColumnLayoutState()
        contentOnly.columnContentWidths = ["c": 180]
        #expect(coordinator.savedColumnLayout(binding: contentOnly) != nil)
    }

    @Test("Duplicate column names round-trip at their own width without growth")
    func duplicateNamesRoundTripWithoutGrowth() throws {
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

        let captured = try #require(coordinator.captureColumnLayout())
        let restored = try #require(coordinator.resolvedColumnLayout(binding: captured, liveWidths: [:]))

        #expect(coordinator.savedColumnLayout(binding: stored)?.columnWidths == ["result": 160])
        #expect(captured.columnWidths == ["result": 176])
        #expect(captured.columnContentWidths == ["result": 176])
        #expect(restored.columnWidths == ["result": 176])
    }

    @Test("Duplicate slots with different accessories still round-trip at one width")
    func mixedDuplicateAccessoriesRoundTrip() throws {
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

        let captured = try #require(coordinator.captureColumnLayout())
        let restored = try #require(coordinator.resolvedColumnLayout(binding: captured, liveWidths: [:]))

        #expect(coordinator.columnPresentation(for: 0, in: rows).accessory == .chevron)
        #expect(coordinator.columnPresentation(for: 1, in: rows).accessory == .foreignKey)
        #expect(captured.columnWidths == ["parent_id": 180])
        #expect(captured.columnContentWidths == ["parent_id": 180])
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

        coordinator.isRebuildingColumns = true
        coordinator.tableViewColumnDidResize(notification)
        #expect(coordinator.userSizedColumnNames.isEmpty)

        coordinator.isRebuildingColumns = false
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

    /// The foreign key arrow arrives with the table's metadata, one round trip after the rows are
    /// already on screen. Widening the column then moves text the user is reading, so the arrow
    /// takes its space from inside the cell instead and the column keeps the width it was given.
    @Test("A late accessory never resizes the column it appears in")
    func lateAccessoryNeverResizesItsColumn() throws {
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

        #expect(column.width == 160)
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == ["parent_id": 160])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == ["parent_id": 160])

        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persister.stored["nodes"]?.columnWidths == ["parent_id": 160])
    }

    /// Losing an accessory is the same rule read backwards: the freed space goes to the text inside
    /// the cell, not back to the window, so the column the user sized keeps the width they gave it.
    @Test("A column that loses its accessory keeps its width")
    func losingAnAccessoryKeepsColumnWidth() throws {
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
        let reconciled = coordinator.liveWidthsForReconciliation(["created_at": column.width])

        #expect(!changes.isEmpty)
        #expect(reconciled == ["created_at": 176])
        #expect(column.width == 176)

        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persister.stored["events"]?.columnWidths == ["created_at": 176])
        #expect(persister.stored["events"]?.columnContentWidths == ["created_at": 176])
    }

    @Test("A query-grid presentation change leaves the pending layout snapshot alone")
    func queryPresentationChangeLeavesPendingLayoutAlone() throws {
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
        coordinator.tableRowsProvider = { dateRows }

        #expect(!changes.isEmpty)
        #expect(column.width == 160)
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnWidths == ["result": 160])
        #expect(coordinator.pendingColumnLayoutPersistence?.layout.columnContentWidths == ["result": 160])

        coordinator.flushPendingColumnLayoutPersistence()

        #expect(persistedLayout?.columnWidths == ["result": 160])
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

    @Test("Reconciliation preserves live widths, presentation change or not")
    func reconciliationPreservesLiveWidths() {
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

        let stable = coordinator.liveWidthsForReconciliation(liveWidths)
        let afterPresentationChange = coordinator.liveWidthsForReconciliation(liveWidths)

        #expect(stable == liveWidths)
        #expect(afterPresentationChange == liveWidths)
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
        let reconciled = coordinator.liveWidthsForReconciliation(["status": 160])

        #expect(!changes.isEmpty)
        #expect(reconciled == ["status": 160])
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
        let reconciled = coordinator.liveWidthsForReconciliation(["date": 176])

        #expect(changes.indices == IndexSet(integer: 0))
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
        let afterAdding = coordinator.liveWidthsForReconciliation(["value": 160])

        coordinator.rebuildColumnMetadataCache(from: plain)
        let removed = coordinator.updateColumnPresentations(from: plain)
        let afterRemoving = coordinator.liveWidthsForReconciliation(afterAdding)

        #expect(!added.isEmpty)
        #expect(afterAdding == ["value": 160])
        #expect(removed.indices.isEmpty)
        #expect(afterRemoving == ["value": 160])
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
        let afterReset = coordinator.liveWidthsForReconciliation(liveWidths)
        let nextUpdate = coordinator.liveWidthsForReconciliation(liveWidths)

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

    /// Both ownership kinds, one rule. An automatic column is sized from its content when the
    /// column is built and a user-sized one is whatever the user dragged it to; the arrow arriving
    /// afterwards re-opens neither decision.
    @Test("Late accessory metadata widens the automatic column and leaves the user-sized one alone")
    func lateAccessoryMetadataWidensAutomaticColumnOnly() throws {
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

        #expect(idColumn.width == 75)
        #expect(coordinator.userSizedColumnNames == ["id"])
        #expect(coordinator.columnPresentation(for: 1, in: rows).accessory == .foreignKey)
        #expect(parentColumn.width > 100)
        #expect(
            DataGridCellAccessory.foreignKey.availableTextWidth(
                in: NSRect(x: 0, y: 0, width: parentColumn.width, height: 24)
            ) >= CGFloat(value.count) * ThemeEngine.shared.dataGridFonts.monoCharWidth
        )

        let widenedWidth = parentColumn.width
        _ = rows.updateDisplayMetadata(columnForeignKeys: [:])
        coordinator.refreshCellPresentations()

        #expect(idColumn.width == 75)
        #expect(parentColumn.width == widenedWidth)
    }

    @Test("Late enum metadata widens the automatic column it appears in")
    func lateEnumMetadataWidensItsColumn() throws {
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

        #expect(coordinator.columnPresentation(for: 0, in: rows).kind == .dropdown)
        #expect(column.width > 100)
        #expect(
            DataGridCellAccessory.chevron.availableTextWidth(
                in: NSRect(x: 0, y: 0, width: column.width, height: 24)
            ) >= CGFloat(value.count) * ThemeEngine.shared.dataGridFonts.monoCharWidth
        )

        let widenedWidth = column.width
        _ = rows.updateDisplayMetadata(columnEnumValues: [:])
        coordinator.refreshCellPresentations()

        #expect(column.width == widenedWidth)
        #expect(coordinator.columnPresentation(for: 0, in: rows).kind == .text)
    }

    @Test("Late metadata waits for an active cell overlay before repainting")
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

        #expect(!editor.isActive)
        #expect(!coordinator.pendingCellPresentationRefresh)
        #expect(column.width > originalWidth)
        #expect(coordinator.columnPresentation(for: 0, in: rows).accessory == .foreignKey)
        #expect(coordinator.userSizedColumnNames.isEmpty)
    }
}
