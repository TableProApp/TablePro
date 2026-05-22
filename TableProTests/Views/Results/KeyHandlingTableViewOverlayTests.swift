//
//  KeyHandlingTableViewOverlayTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class StubColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}
    func clear(for tableName: String, connectionId: UUID) {}
}

@Suite("KeyHandlingTableView overlay raise")
@MainActor
struct KeyHandlingTableViewOverlayTests {
    private func makeCoordinator() -> TableViewCoordinator {
        TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
    }

    @Test("adding a subview while an overlay is active raises it to front without trapping")
    func addingSubviewRaisesActiveOverlay() {
        let tableView = KeyHandlingTableView()
        let coordinator = makeCoordinator()
        tableView.coordinator = coordinator

        let editor = CellOverlayEditor()
        coordinator.overlayEditor = editor
        let container = CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        editor.install(in: tableView, row: 0, column: 0, columnIndex: 0, container: container)

        tableView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))

        #expect(tableView.subviews.last === container)

        editor.removeOverlay()
    }
}
