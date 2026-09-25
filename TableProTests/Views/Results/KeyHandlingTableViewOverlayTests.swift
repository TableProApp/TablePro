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

    @Test("adding a subview to the table leaves the selection overlay above it")
    func addingSubviewKeepsSelectionOverlayOnTop() {
        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let selectionOverlay = GridSelectionOverlay(frame: tableView.bounds)
        tableView.selectionOverlay = selectionOverlay
        tableView.addSubview(selectionOverlay)

        tableView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))

        #expect(tableView.subviews.last === selectionOverlay)
    }

    @Test("an open overlay is mounted beside the table, above the rows")
    func openOverlayIsMountedBesideTheTable() {
        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let coordinator = makeCoordinator()
        tableView.coordinator = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = tableView

        let editor = CellOverlayEditor()
        coordinator.overlayEditor = editor
        let container = CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        editor.install(in: tableView, row: 0, column: 0, columnIndex: 0, container: container)

        let subviews = scrollView.subviews
        let clipIndex = subviews.firstIndex { $0 === scrollView.contentView }
        #expect(editor.isActive)
        #expect(!container.isDescendant(of: tableView))
        #expect(clipIndex.map { $0 + 1 } == subviews.firstIndex { $0 === container })

        editor.removeOverlay()
        #expect(container.superview == nil)
    }

    @Test("a table outside a scroll view opens no overlay")
    func tableWithoutScrollViewOpensNoOverlay() {
        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let coordinator = makeCoordinator()
        tableView.coordinator = coordinator

        let editor = CellOverlayEditor()
        coordinator.overlayEditor = editor
        let container = CellOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        editor.install(in: tableView, row: 0, column: 0, columnIndex: 0, container: container)

        #expect(!editor.isActive)
        #expect(container.superview == nil)
    }
}
