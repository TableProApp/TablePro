//
//  KeyHandlingTableViewCopyTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class KeyHandlingCopyLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class KeyHandlingCopyDelegateSpy: DataGridViewDelegate {
    var copiedRows: Set<Int>?
    var deletedRows: Set<Int>?

    func dataGridCopyRows(_ indices: Set<Int>) {
        copiedRows = indices
    }

    func dataGridDeleteRows(_ indices: Set<Int>) {
        deletedRows = indices
    }
}

@Suite("KeyHandlingTableView selection-scoped commands")
@MainActor
struct KeyHandlingTableViewCopyTests {
    private func makeSUT(
        delegate: any DataGridViewDelegate
    ) -> (KeyHandlingTableView, TableViewCoordinator) {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: KeyHandlingCopyLayoutPersister()
        )
        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        coordinator.tableView = tableView
        return (tableView, coordinator)
    }

    private func applyRangeSelection(to coordinator: TableViewCoordinator) {
        coordinator.selectionController.update(
            .single(
                GridRect(rows: 0...1, columns: 0...1),
                anchor: GridCoord(row: 0, column: 0),
                active: GridCoord(row: 1, column: 0)
            )
        )
    }

    @Test("Copy Rows sends every row of the range selection")
    func copyRowsAsTsvUsesRangeSelection() {
        let delegate = KeyHandlingCopyDelegateSpy()
        let (tableView, coordinator) = makeSUT(delegate: delegate)
        applyRangeSelection(to: coordinator)

        tableView.copyRowsAsTSV(nil)

        #expect(delegate.copiedRows == Set([0, 1]))
    }

    @Test("Delete removes every row of the range selection")
    func deleteUsesRangeSelection() {
        let delegate = KeyHandlingCopyDelegateSpy()
        let (tableView, coordinator) = makeSUT(delegate: delegate)
        applyRangeSelection(to: coordinator)

        tableView.delete(nil)

        #expect(delegate.deletedRows == Set([0, 1]))
    }

    @Test("Copy Rows stays enabled when only a range selection exists")
    func validateCopyRowsWithRangeSelectionOnly() {
        let delegate = KeyHandlingCopyDelegateSpy()
        let (tableView, coordinator) = makeSUT(delegate: delegate)
        applyRangeSelection(to: coordinator)

        let item = NSMenuItem(
            title: "Copy Rows",
            action: #selector(KeyHandlingTableView.copyRowsAsTSV(_:)),
            keyEquivalent: ""
        )

        #expect(tableView.validateUserInterfaceItem(item))
    }

    @Test("Copy Rows stays disabled without any selection")
    func validateCopyRowsWithoutSelection() {
        let delegate = KeyHandlingCopyDelegateSpy()
        let (tableView, _) = makeSUT(delegate: delegate)

        let item = NSMenuItem(
            title: "Copy Rows",
            action: #selector(KeyHandlingTableView.copyRowsAsTSV(_:)),
            keyEquivalent: ""
        )

        #expect(!tableView.validateUserInterfaceItem(item))
    }
}
