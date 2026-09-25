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
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("KeyHandlingTableView overlay stacking")
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

    @Test("adding a subview to the table while an overlay is open leaves the overlay above every row")
    func addingSubviewKeepsOverlayAboveRows() {
        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let coordinator = makeCoordinator()
        tableView.coordinator = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = tableView

        let editor = CellOverlayEditor()
        coordinator.overlayEditor = editor
        let container = CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        editor.install(in: tableView, row: 0, column: 0, columnIndex: 0, container: container)

        tableView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))

        let subviews = scrollView.subviews
        let clipIndex = subviews.firstIndex { $0 === scrollView.contentView }
        let overlayIndex = subviews.firstIndex { $0 === container }
        #expect(container.superview === scrollView)
        #expect(clipIndex.map { $0 + 1 } == overlayIndex)

        editor.removeOverlay()
    }

    @Test("a table outside a scroll view hosts its own overlay")
    func tableWithoutScrollViewHostsTheOverlay() {
        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let coordinator = makeCoordinator()
        tableView.coordinator = coordinator

        let editor = CellOverlayEditor()
        coordinator.overlayEditor = editor
        let container = CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        editor.install(in: tableView, row: 0, column: 0, columnIndex: 0, container: container)

        #expect(container.superview === tableView)

        editor.removeOverlay()
        #expect(container.superview == nil)
    }
}
