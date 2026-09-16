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

    private let storedDocument = #"{"id": 1, "name": "example"}"#

    /// PostgreSQL stores `json` text verbatim, so a cell the user only looked at must write back
    /// the bytes the server sent. The editor shows every element pretty-printed, and without this
    /// pressing OK would rewrite all of them.
    @Test("An element the user only read commits the bytes the server sent")
    func keepsUntouchedJsonElementByteIdentical() {
        var rows = ArrayValueEditorModel.rows(from: [.value(storedDocument), .value(#"{"id": 2}"#)])
        rows[0].element = .value("{\n  \"id\": 1,\n  \"name\": \"example\"\n}")

        let literal = ArrayValueEditorModel.literal(from: rows, delimiter: ",", elementEditor: .json)
        #expect(PostgresArrayLiteralCodec.parse(literal) == [.value(storedDocument), .value(#"{"id": 2}"#)])
    }

    @Test("An element the user changed commits compact, the way the JSON cell editor does")
    func commitsEditedJsonElementCompact() {
        var rows = ArrayValueEditorModel.rows(from: [.value(storedDocument)])
        rows[0].element = .value("{\n  \"id\": 2,\n  \"name\": \"example\"\n}")

        let literal = ArrayValueEditorModel.literal(from: rows, delimiter: ",", elementEditor: .json)
        #expect(PostgresArrayLiteralCodec.parse(literal) == [.value(#"{"id":2,"name":"example"}"#)])
    }

    @Test("A row the user added carries no original, so it commits what was typed")
    func commitsAddedJsonElementAsTyped() {
        let rows = [ArrayEditorRow(element: .value(#"{"id": 3}"#))]
        let literal = ArrayValueEditorModel.literal(from: rows, delimiter: ",", elementEditor: .json)
        #expect(PostgresArrayLiteralCodec.parse(literal) == [.value(#"{"id":3}"#)])
    }

    /// A scalar array can hold text that happens to parse as JSON, and there retyping the
    /// whitespace inside it is a real edit rather than the same document.
    @Test("The rule is confined to JSON elements")
    func leavesScalarElementsAlone() {
        var rows = ArrayValueEditorModel.rows(from: [.value(storedDocument)])
        rows[0].element = .value(#"{"id":1,"name":"example"}"#)

        let literal = ArrayValueEditorModel.literal(from: rows, delimiter: ",", elementEditor: .scalar)
        #expect(PostgresArrayLiteralCodec.parse(literal) == [.value(#"{"id":1,"name":"example"}"#)])
    }

    @Test("A SQL NULL element stays SQL NULL and a JSON null element stays JSON null")
    func keepsNullKindsDistinctThroughACommit() {
        let rows = ArrayValueEditorModel.rows(from: [.null, .value("null")])
        let literal = ArrayValueEditorModel.literal(from: rows, delimiter: ",", elementEditor: .json)
        #expect(literal == #"{NULL,"null"}"#)
        #expect(PostgresArrayLiteralCodec.parse(literal) == [.null, .value("null")])
    }

    @Test("A JSON element's list summary is compact, and NULL has none of its own")
    func summarisesJsonElements() {
        #expect(ArrayValueEditorModel.jsonDisplay(of: .value(storedDocument)).summary == #"{"id":1,"name":"example"}"#)
        #expect(ArrayValueEditorModel.jsonDisplay(of: .null).summary == nil)
        #expect(ArrayValueEditorModel.jsonDisplay(of: .null).isValid)
        #expect(ArrayValueEditorModel.jsonDisplay(of: .value("{oops")).isValid == false)
        let long = ArrayValueEditorModel.jsonDisplay(of: .value(String(repeating: "a", count: 40)), limit: 8)
        #expect(long.summary?.count == 9)
    }

    /// The element list rebuilds on every keystroke in the detail editor, so parsing each visible
    /// element per render is unbounded work on the main actor. Past the cap an element is previewed
    /// from its prefix and reports no verdict rather than a wrong one.
    @Test("An element too large to inspect is previewed without being parsed")
    func doesNotParseAnOversizeElement() {
        let oversize = "{\"k\": \"" + String(repeating: "x", count: 8_000) + "\"}"
        let display = ArrayValueEditorModel.jsonDisplay(of: .value(oversize), limit: 40)
        #expect(display.isValid)
        #expect(display.summary?.count == 41)
        #expect(display.summary?.hasPrefix("{\"k\": \"xxx") == true)

        let oversizeAndBroken = "{" + String(repeating: "x", count: 8_000)
        #expect(ArrayValueEditorModel.jsonDisplay(of: .value(oversizeAndBroken)).isValid)
    }
}
