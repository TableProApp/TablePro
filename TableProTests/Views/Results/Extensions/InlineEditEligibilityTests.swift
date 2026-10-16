//
//  InlineEditEligibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StubColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

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

    private func makeNewRowCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: [[.text("0b8f6c1e-4a7e-4d43-9d0c-2f4c5b6a7e81"), .bytes(Data([1])), .null, .null]],
            columns: ["id", "photo", "name", "note"],
            columnTypes: [.text(rawType: "uuid"), .blob(rawType: "bytea"), .text(rawType: "text"), .text(rawType: "text")]
        )
        coordinator.tableRowsProvider = { tableRows }
        return coordinator
    }

    @Test("The caret on a new row passes over the columns it was given a value for")
    func caretSkipsPrefilledColumns() {
        let coordinator = makeNewRowCoordinator()

        #expect(coordinator.firstEditableColumn(displayRow: 0) == 0)
        #expect(coordinator.firstEditableColumn(displayRow: 0, skipping: [0]) == 2)
        #expect(coordinator.firstEditableColumn(displayRow: 0, skipping: [0, 2]) == 3)
    }

    @Test("When every editable column was given a value the caret still opens on the first of them")
    func caretFallsBackToAPrefilledColumn() {
        let coordinator = makeNewRowCoordinator()

        #expect(coordinator.firstEditableColumn(displayRow: 0, skipping: [0, 2, 3]) == 0)
    }
}
