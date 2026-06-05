//
//  InlineEditEligibilityTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StubColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}
    func clear(for tableName: String, connectionId: UUID) {}
}

@Suite("Inline edit eligibility")
@MainActor
struct InlineEditEligibilityTests {
    private func makeCoordinator(columnType: ColumnType, value: String) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: [[PluginCellValue.text(value)]],
            columns: ["col"],
            columnTypes: [columnType]
        )
        coordinator.tableRowsProvider = { tableRows }
        return coordinator
    }

    @Test("JSON column is eligible for inline editing")
    func jsonColumnIsInlineEditable() {
        let coordinator = makeCoordinator(columnType: .json(rawType: "JSON"), value: #"{"k":1}"#)
        #expect(coordinator.canStartInlineEdit(row: 0, columnIndex: 0))
    }

    @Test("BLOB column is not eligible for inline editing")
    func blobColumnIsNotInlineEditable() {
        let coordinator = makeCoordinator(columnType: .blob(rawType: "BLOB"), value: "x")
        #expect(!coordinator.canStartInlineEdit(row: 0, columnIndex: 0))
    }

    @Test("plain text column is eligible for inline editing")
    func textColumnIsInlineEditable() {
        let coordinator = makeCoordinator(columnType: .text(rawType: "TEXT"), value: "hello")
        #expect(coordinator.canStartInlineEdit(row: 0, columnIndex: 0))
    }
}
