//
//  InlineEditEligibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Which cells take the text editor: the gate every way into editing (Return, a click, Tab, an owner) goes through.
@MainActor
struct InlineEditEligibilityTests {
    private func makeGrid(
        columnType: ColumnType,
        value: PluginCellValue,
        configure: (inout DataGridConfiguration) -> Void = { _ in },
        unloaded: Bool = false
    ) -> EditingGrid {
        var configuration = EditingGrid.editable
        configure(&configuration)
        let rows = TableRows.from(
            queryRows: [[value]],
            columns: ["col"],
            columnTypes: [columnType],
            unloadedCells: unloaded ? [0: [0: 1_024]] : [:]
        )
        return EditingGrid(rows: rows, configuration: configuration)
    }

    private func editableText(_ grid: EditingGrid) -> String? {
        guard let cell = grid.controller.editCell(at: GridCoord(row: 0, displayColumn: 0)) else { return nil }
        return grid.controller.textEditableValue(of: cell)
    }

    @Test("A JSON column takes the text editor")
    func jsonColumnIsEditable() {
        let grid = makeGrid(columnType: .json(rawType: "JSON"), value: .text(#"{"k":1}"#))
        defer { grid.tearDown() }

        #expect(editableText(grid) == #"{"k":1}"#)
    }

    @Test("A BLOB column does not; its editor is the hex popover")
    func blobColumnIsNotEditable() {
        let grid = makeGrid(columnType: .blob(rawType: "BLOB"), value: .text("x"))
        defer { grid.tearDown() }

        #expect(editableText(grid) == nil)
    }

    @Test("Bytes in a text column do not either")
    func bytesAreNotEditable() {
        let grid = makeGrid(columnType: .text(rawType: "TEXT"), value: .bytes(Data([0xDE, 0xAD])))
        defer { grid.tearDown() }

        #expect(editableText(grid) == nil)
    }

    @Test("A plain text column takes it, and a NULL opens as empty text")
    func textColumnIsEditable() {
        let text = makeGrid(columnType: .text(rawType: "TEXT"), value: .text("hello"))
        defer { text.tearDown() }
        let null = makeGrid(columnType: .text(rawType: "TEXT"), value: .null)
        defer { null.tearDown() }

        #expect(editableText(text) == "hello")
        #expect(editableText(null) == "")
    }

    @Test("A read-only grid and a locked column take no text")
    func readOnlyAndLockedAreNotEditable() {
        let readOnly = makeGrid(columnType: .text(rawType: "TEXT"), value: .text("a")) { $0.isEditable = false }
        defer { readOnly.tearDown() }
        let locked = makeGrid(columnType: .text(rawType: "TEXT"), value: .text("a")) { $0.lockedColumns = ["col"] }
        defer { locked.tearDown() }

        #expect(editableText(readOnly) == nil)
        #expect(editableText(locked) == nil)
    }

    // Its NULL stands for a value still on the server, which no edit may replace unread (#3758).
    @Test("A value the page left on the server takes no text until it loads")
    func unloadedValueIsNotEditable() {
        let grid = makeGrid(columnType: .text(rawType: "TEXT"), value: .null, unloaded: true)
        defer { grid.tearDown() }

        #expect(editableText(grid) == nil)
    }
}
