//
//  DataGridColumnWidthOwnershipTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Legacy column width ownership")
@MainActor
struct DataGridColumnWidthOwnershipTests {
    private static let plainWidth: CGFloat = 210
    private static let actionWidth: CGFloat = 168

    private func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopColumnLayoutPersister()
        )
        coordinator.tabType = .table
        coordinator.connectionId = UUID()
        coordinator.tableName = "machines"
        return coordinator
    }

    private func makeRows() -> TableRows {
        TableRows.from(
            queryRows: [[.text("edge-01"), .text("2026-08-20 11:03:39")]],
            columns: ["machine_id", "last_seen_at"],
            columnTypes: [.text(rawType: "TEXT"), .date(rawType: "DATETIME")]
        )
    }

    private func attach(_ rows: TableRows, to coordinator: TableViewCoordinator) -> [String: NSTableColumn] {
        let tableView = NSTableView()
        coordinator.tableView = tableView
        coordinator.tableRowsProvider = { rows }
        coordinator.rebuildColumnMetadataCache(from: rows)

        var result: [String: NSTableColumn] = [:]
        for (index, name) in rows.columns.enumerated() {
            let identifier = coordinator.columnIdentifier(for: index) ?? ColumnIdentitySchema.slotIdentifier(index)
            let column = NSTableColumn(identifier: identifier)
            column.width = name == "machine_id" ? Self.plainWidth : Self.actionWidth
            tableView.addTableColumn(column)
            result[name] = column
        }
        coordinator.updateColumnPresentations(from: rows)
        return result
    }

    private func legacyLayout() -> ColumnLayoutState {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["machine_id": Self.plainWidth, "last_seen_at": Self.actionWidth]
        layout.columnOrder = ["machine_id", "last_seen_at"]
        layout.hiddenColumns = ["machine_id"]
        return layout
    }

    @Test("A legacy layout drops the width of a column that draws an action button")
    func legacyLayoutDropsActionColumnWidth() throws {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        _ = attach(rows, to: coordinator)

        let resolved = try #require(coordinator.layoutDiscardingUnownedWidths(legacyLayout(), tableRows: rows))

        #expect(coordinator.columnPresentation(for: 1, in: rows).accessory == .chevron)
        #expect(resolved.columnWidths["last_seen_at"] == nil)
        #expect(resolved.columnWidths["machine_id"] == Self.plainWidth)
    }

    @Test("A legacy layout keeps the order and hidden columns it recorded")
    func legacyLayoutKeepsOrderAndHiddenColumns() throws {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        _ = attach(rows, to: coordinator)

        let resolved = try #require(coordinator.layoutDiscardingUnownedWidths(legacyLayout(), tableRows: rows))

        #expect(resolved.columnOrder == ["machine_id", "last_seen_at"])
        #expect(resolved.hiddenColumns == ["machine_id"])
    }

    @Test("A layout that records ownership is returned unchanged")
    func ownedLayoutIsUntouched() throws {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        _ = attach(rows, to: coordinator)

        var layout = legacyLayout()
        layout.columnContentWidths = layout.columnWidths

        let resolved = try #require(coordinator.layoutDiscardingUnownedWidths(layout, tableRows: rows))

        #expect(resolved.columnWidths["last_seen_at"] == Self.actionWidth)
        #expect(resolved.columnWidths["machine_id"] == Self.plainWidth)
    }

    @Test("A legacy width the user has taken ownership of is kept")
    func legacyWidthKeptOnceUserSized() throws {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        let columns = attach(rows, to: coordinator)

        #expect(coordinator.markColumnWidthUserSized(try #require(columns["last_seen_at"])))
        let resolved = try #require(coordinator.layoutDiscardingUnownedWidths(legacyLayout(), tableRows: rows))

        #expect(resolved.columnWidths["last_seen_at"] == Self.actionWidth)
    }

    @Test("A layout with no widths at all is returned unchanged")
    func emptyLayoutIsUntouched() throws {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        _ = attach(rows, to: coordinator)

        var layout = ColumnLayoutState()
        layout.columnOrder = ["machine_id", "last_seen_at"]

        let resolved = try #require(coordinator.layoutDiscardingUnownedWidths(layout, tableRows: rows))

        #expect(resolved.columnWidths.isEmpty)
        #expect(resolved.columnOrder == ["machine_id", "last_seen_at"])
    }

    /// A foreign key arrow is only known after the metadata round trip, so a legacy layout is
    /// restored before anything can tell that column apart from a plain one. It still carries no
    /// ownership, so the arrow arriving has to be allowed to widen it.
    @Test("A legacy width still widens when its accessory resolves after the restore")
    func legacyWidthWidensWhenAccessoryResolvesLate() throws {
        let coordinator = makeCoordinator()
        var rows = TableRows.from(
            queryRows: [[.text(String(repeating: "M", count: 20))]],
            columns: ["parent_id"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let tableView = NSTableView()
        coordinator.tableView = tableView
        coordinator.tableRowsProvider = { rows }
        coordinator.rebuildColumnMetadataCache(from: rows)
        let identifier = try #require(coordinator.columnIdentifier(for: 0))
        let column = NSTableColumn(identifier: identifier)
        column.width = Self.actionWidth
        tableView.addTableColumn(column)
        coordinator.updateColumnPresentations(from: rows)

        var legacy = ColumnLayoutState()
        legacy.columnWidths = ["parent_id": Self.actionWidth]
        legacy.columnOrder = ["parent_id"]
        let restored = coordinator.layoutDiscardingUnownedWidths(legacy, tableRows: rows)
        coordinator.synchronizeUserSizedColumns(
            with: restored,
            columns: rows.columns,
            tableIdentityChanged: true
        )

        #expect(restored?.columnWidths["parent_id"] == Self.actionWidth)
        #expect(coordinator.userSizedColumnNames == ["parent_id"])
        #expect(coordinator.unownedRestoredColumnNames == ["parent_id"])

        _ = rows.updateDisplayMetadata(columnForeignKeys: [
            "parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id"),
        ])
        coordinator.refreshCellPresentations()

        #expect(coordinator.columnPresentation(for: 0, in: rows).accessory == .foreignKey)
        #expect(column.width > Self.actionWidth)
    }

    @Test("A width the user sizes stops counting as an unowned restore")
    func userResizeClearsUnownedRestore() throws {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        let columns = attach(rows, to: coordinator)
        _ = coordinator.layoutDiscardingUnownedWidths(legacyLayout(), tableRows: rows)

        #expect(coordinator.unownedRestoredColumnNames.contains("machine_id"))
        #expect(coordinator.markColumnWidthUserSized(try #require(columns["machine_id"])))
        #expect(!coordinator.unownedRestoredColumnNames.contains("machine_id"))
    }

    @Test("A nil layout stays nil")
    func nilLayoutStaysNil() {
        let coordinator = makeCoordinator()
        let rows = makeRows()
        _ = attach(rows, to: coordinator)

        #expect(coordinator.layoutDiscardingUnownedWidths(nil, tableRows: rows) == nil)
    }
}
