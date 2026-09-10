//
//  ArrayValueEditorModelTests.swift
//  TableProTests
//
//  Tests for the array cell editor's row model.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Array Value Editor Model")
struct ArrayValueEditorModelTests {
    private let labels = ["sad", "ok", "happy"]

    @Test("Rows keep duplicate elements distinct")
    func rowsKeepDuplicatesDistinct() {
        let rows = ArrayValueEditorModel.rows(from: [.value("sad"), .value("sad")])
        #expect(rows.count == 2)
        #expect(rows[0].id != rows[1].id)
        #expect(rows[0].element == rows[1].element)
    }

    @Test("A value the type no longer declares stays selectable")
    func keepsDriftedValueSelectable() {
        let options = ArrayValueEditorModel.pickerOptions(for: .value("retired"), allowedValues: labels)
        #expect(options == ["sad", "ok", "happy", "retired"])
        #expect(ArrayValueEditorModel.selectionIndex(for: .value("retired"), in: options) == 3)
        #expect(ArrayValueEditorModel.isDriftedValue(.value("retired"), allowedValues: labels))
        #expect(!ArrayValueEditorModel.isDriftedValue(.value("sad"), allowedValues: labels))
        #expect(!ArrayValueEditorModel.isDriftedValue(.null, allowedValues: labels))
    }

    @Test("A known value does not widen the option list")
    func doesNotWidenOptionsForKnownValue() {
        #expect(ArrayValueEditorModel.pickerOptions(for: .value("ok"), allowedValues: labels) == labels)
        #expect(ArrayValueEditorModel.pickerOptions(for: .null, allowedValues: labels) == labels)
    }

    @Test("The index past the last label selects NULL")
    func mapsTrailingIndexToNull() {
        #expect(ArrayValueEditorModel.selectionIndex(for: .null, in: labels) == labels.count)
        #expect(ArrayValueEditorModel.element(atSelectionIndex: labels.count, in: labels) == .null)
        #expect(ArrayValueEditorModel.element(atSelectionIndex: 1, in: labels) == .value("ok"))
        #expect(ArrayValueEditorModel.element(atSelectionIndex: 99, in: labels) == .null)
    }

    @Test("Reordering swaps neighbours and ignores moves off the ends")
    func reordersWithinBounds() {
        let rows = ArrayValueEditorModel.rows(from: [.value("a"), .value("b"), .value("c")])
        let movedDown = ArrayValueEditorModel.moved(rows, from: 0, by: 1)
        #expect(movedDown.map(\.element) == [.value("b"), .value("a"), .value("c")])

        let movedUp = ArrayValueEditorModel.moved(rows, from: 2, by: -1)
        #expect(movedUp.map(\.element) == [.value("a"), .value("c"), .value("b")])

        #expect(ArrayValueEditorModel.moved(rows, from: 0, by: -1).map(\.element) == rows.map(\.element))
        #expect(ArrayValueEditorModel.moved(rows, from: 2, by: 1).map(\.element) == rows.map(\.element))
    }

    @Test("Rows are removed and reordered by identity, so duplicates stay independent")
    func mutatesByIdentity() {
        let rows = ArrayValueEditorModel.rows(from: [.value("a"), .value("b"), .value("a")])
        let removedFirst = ArrayValueEditorModel.removing(rows, id: rows[0].id)
        #expect(removedFirst.map(\.element) == [.value("b"), .value("a")])
        #expect(removedFirst.count == 2)

        let movedLastUp = ArrayValueEditorModel.moved(rows, id: rows[2].id, by: -1)
        #expect(movedLastUp.map(\.id) == [rows[0].id, rows[2].id, rows[1].id])

        #expect(ArrayValueEditorModel.moved(rows, id: rows[0].id, by: -1).map(\.id) == rows.map(\.id))
        #expect(ArrayValueEditorModel.moved(rows, id: UUID(), by: 1).map(\.id) == rows.map(\.id))
        #expect(ArrayValueEditorModel.removing(rows, id: UUID()).count == 3)
    }

    @Test("The committed literal preserves order and quotes hostile labels")
    func buildsLiteralFromRows() {
        let rows = ArrayValueEditorModel.rows(from: [.value("happy"), .null, .value("a,b")])
        let literal = ArrayValueEditorModel.literal(from: rows, delimiter: ",")
        #expect(literal == #"{happy,NULL,"a,b"}"#)
        #expect(PostgresArrayLiteralCodec.parse(literal) == rows.map(\.element))
    }

    @Test("An empty row list commits an empty array, not NULL")
    func buildsEmptyArrayLiteral() {
        #expect(ArrayValueEditorModel.literal(from: [], delimiter: ",") == "{}")
    }
}
