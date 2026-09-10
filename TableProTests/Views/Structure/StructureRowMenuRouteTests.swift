//
//  StructureRowMenuRouteTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StructureRouteLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// A column row raises the same menu whichever way AppKit reaches it.
///
/// There are two routes and they used to end in two different menus.
/// `KeyHandlingTableView.rightMouseDown` intercepts a click that lands inside the selection and
/// answers from `DataGridRowView.contextMenu(for:)`; a click outside the selection falls through to
/// `super`, which reaches the row view's own `menu(for:)`. The Structure tab overrode only the
/// second, so selecting a column and right-clicking it produced the data grid's row commands over a
/// schema row.
///
/// Asserted here rather than in a UI test because XCUITest cannot tell the two menus apart in this
/// runner: an open contextual menu is not a child of the application element, and the titles that
/// would discriminate (`Export Results…`) also sit in the menu bar, so an app-rooted query answers
/// from there whatever the contextual menu holds.
@Suite("Structure row menu route")
@MainActor
struct StructureRowMenuRouteTests {
    /// Only the structure menu builds this.
    private let structureOnly = "Copy Name"
    /// Only the data grid's row menu builds this.
    private let dataGridOnly = "Export Results…"

    private func makeRowView(tab: StructureTab = .columns) -> StructureRowViewWithMenu {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StructureRouteLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: [[.text("id")]], columns: ["Name"], columnTypes: [.text(rawType: "TEXT")]
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView

        let rowView = StructureRowViewWithMenu()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0
        rowView.structureTab = tab
        return rowView
    }

    private func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map(\.title)
    }

    @Test("The route a click outside the selection takes builds the structure menu")
    func theUnselectedRouteBuildsTheStructureMenu() throws {
        let rowView = makeRowView()
        let items = titles(rowView.menu(for: try rightClick()))

        #expect(items.contains(structureOnly))
        #expect(!items.contains(dataGridOnly))
    }

    @Test("The route a click inside the selection takes builds the structure menu too")
    func theSelectedRouteBuildsTheStructureMenu() throws {
        let rowView = makeRowView()
        let items = titles(rowView.contextMenu(for: try rightClick()))

        #expect(items.contains(structureOnly))
        #expect(!items.contains(dataGridOnly))
    }

    /// Not a column list, so neither route offers a menu at all.
    @Test("A DDL tab row raises no menu on either route")
    func theDdlTabRaisesNoMenu() throws {
        let rowView = makeRowView(tab: .ddl)

        #expect(rowView.menu(for: try rightClick()) == nil)
        #expect(rowView.contextMenu(for: try rightClick()) == nil)
    }
}
