//
//  MultiRowEditStateClearedFieldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StagedFieldRecorder {
    var values: [Int: PluginCellValue] = [:]
    var detachedValues: [Int: PluginCellValue] = [:]
}

@MainActor
struct MultiRowEditStateClearedFieldTests {
    private static let columns = ["id", "deleted_at", "name", "doc", "created_at"]
    private static let deletedAt = 1
    private static let name = 2
    private static let doc = 3
    private static let createdAt = 4

    private func makeState(_ recorder: StagedFieldRecorder) -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            selectedRowIndices: [0],
            rowIDs: [.existing(0)],
            allRows: [["1", "2024-01-01 10:00:00", "Alice", "{\"a\":1}", "2023-12-01 09:00:00"]],
            columns: Self.columns,
            columnTypes: [
                .integer(rawType: "INT"),
                .datetime(rawType: "DATETIME"),
                .text(rawType: "VARCHAR(255)"),
                .json(rawType: "JSON"),
                .timestamp(rawType: "TIMESTAMP")
            ],
            nonNullableColumns: ["created_at"]
        )
        state.onFieldChanged = { index, value, _ in recorder.values[index] = value }
        state.onDetachedFieldChanged = { index, value, _, _ in recorder.detachedValues[index] = value }
        return state
    }

    @Test("Clearing a date field stages NULL and keeps the field's text editable")
    func clearedDateFieldStagesNull() {
        let recorder = StagedFieldRecorder()
        let state = makeState(recorder)

        state.updateField(at: Self.deletedAt, value: "")

        #expect(recorder.values[Self.deletedAt] == .null)
        #expect(state.fields[Self.deletedAt].isPendingNull == false)
        #expect(state.currentText(at: Self.deletedAt) == "")
    }

    @Test("Clearing a text field stages the empty string")
    func clearedTextFieldStagesEmpty() {
        let recorder = StagedFieldRecorder()
        let state = makeState(recorder)

        state.updateField(at: Self.name, value: "")

        #expect(recorder.values[Self.name] == .text(""))
    }

    @Test("Clearing a NOT NULL timestamp field stages nothing and keeps the stored value")
    func clearedNotNullFieldIsRefused() {
        let recorder = StagedFieldRecorder()
        let state = makeState(recorder)

        state.updateField(at: Self.createdAt, value: "")

        #expect(recorder.values[Self.createdAt] == nil)
        #expect(state.fields[Self.createdAt].hasEdit == false)
        #expect(state.currentText(at: Self.createdAt) == "2023-12-01 09:00:00")
    }

    @Test("Clearing a NOT NULL timestamp after typing in it takes the typed value back out")
    func clearedNotNullFieldRevertsTypedValue() {
        let recorder = StagedFieldRecorder()
        let state = makeState(recorder)

        state.updateField(at: Self.createdAt, value: "2024-05-05 00:00:00")
        state.updateField(at: Self.createdAt, value: "")

        #expect(recorder.values[Self.createdAt] == .text("2023-12-01 09:00:00"))
        #expect(state.fields[Self.createdAt].hasEdit == false)
    }

    @Test("A detached window's cleared JSON goes to its rows as NULL")
    func clearedDetachedJSONStagesNull() {
        let recorder = StagedFieldRecorder()
        let state = makeState(recorder)

        state.updateDetachedField(columnIndex: Self.doc, rowIDs: [.existing(7)], value: "")

        #expect(recorder.detachedValues[Self.doc] == .null)
    }
}
