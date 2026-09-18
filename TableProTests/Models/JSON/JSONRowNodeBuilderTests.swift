//
//  JSONRowNodeBuilderTests.swift
//  TableProTests
//
//  Whether a value prints quoted comes from the column's own type, not from the text.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("JSONRowNodeBuilder")
struct JSONRowNodeBuilderTests {
    private func reference(column: String, table: String = "language") -> JSONForeignKeyRef {
        JSONForeignKeyRef(
            column: column,
            referencedTable: table,
            referencedSchema: nil,
            referencedColumn: "\(table)_id"
        )
    }

    private func node(_ root: JSONRowNode, _ column: String) throws -> JSONRowNode {
        try #require(root.children.first { $0.key == .name(column) })
    }

    @Test("The column type decides the scalar kind")
    func typesScalars() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["film_id", "rental_rate", "title", "active", "last_update"],
            values: [.text("2"), .text("4.99"), .text("ACE GOLDFINGER"), .text("true"), .text("2006-02-15 05:03:42")],
            columnTypes: [
                .integer(rawType: "INT"),
                .decimal(rawType: "NUMERIC(5,2)"),
                .text(rawType: "VARCHAR"),
                .boolean(rawType: "BOOL"),
                .timestamp(rawType: "TIMESTAMP"),
            ],
            foreignKeys: [:]
        )

        #expect(try node(root, "film_id").scalar == .number("2"))
        #expect(try node(root, "rental_rate").scalar == .number("4.99"))
        #expect(try node(root, "title").scalar == .string("ACE GOLDFINGER"))
        #expect(try node(root, "active").scalar == .bool(true))
        #expect(try node(root, "last_update").scalar == .string("2006-02-15 05:03:42"))
    }

    @Test("A boolean column reads the spellings the drivers emit")
    func typesBooleans() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["a", "b", "c"],
            values: [.text("false"), .text("0"), .text("maybe")],
            columnTypes: [
                .boolean(rawType: "BOOL"),
                .boolean(rawType: "TINYINT(1)"),
                .boolean(rawType: "BOOL"),
            ],
            foreignKeys: [:]
        )
        #expect(try node(root, "a").scalar == .bool(false))
        #expect(try node(root, "b").scalar == .bool(false))
        #expect(try node(root, "c").scalar == .string("maybe"))
    }

    @Test("An integer column holding text that is not a number stays a string")
    func keepsUnparsableNumbersAsStrings() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["n"],
            values: [.text("twelve")],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: [:]
        )
        #expect(try node(root, "n").scalar == .string("twelve"))
    }

    @Test("An integer wider than a Double keeps its digits")
    func preservesWideIntegers() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["n"],
            values: [.text("9007199254740993")],
            columnTypes: [.integer(rawType: "BIGINT")],
            foreignKeys: [:]
        )
        #expect(try node(root, "n").scalar == .number("9007199254740993"))
    }

    @Test("NULL and binary values keep their own kinds")
    func typesNullAndBinary() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["note", "thumb"],
            values: [.null, .bytes(Data([0x4C, 0x65]))],
            columnTypes: [.text(rawType: "TEXT"), .blob(rawType: "BLOB")],
            foreignKeys: [:]
        )
        #expect(try node(root, "note").scalar == .null)
        #expect(try node(root, "thumb").scalar == .binary(Data([0x4C, 0x65])))
    }

    @Test("A JSON column expands into a subtree")
    func expandsJsonColumns() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text("{\"a\": [1, 2], \"b\": null}")],
            columnTypes: [.json(rawType: "JSONB")],
            foreignKeys: [:]
        )
        let payload = try node(root, "payload")
        #expect(payload.isContainer)
        #expect(payload.children.count == 2)
        #expect(payload.children[0].children.map(\.scalar) == [.number("1"), .number("2")])
        #expect(payload.children[1].scalar == .null)
    }

    @Test("A TEXT column holding a document expands too")
    func expandsTextColumnsHoldingDocuments() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text("[\"Trailers\"]")],
            columnTypes: [.text(rawType: "TEXT")],
            foreignKeys: [:]
        )
        let payload = try node(root, "payload")
        #expect(payload.isContainer)
        #expect(payload.children.map(\.scalar) == [.string("Trailers")])
    }

    @Test("A TEXT column holding ordinary prose stays a string")
    func leavesProseAlone() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["description"],
            values: [.text("A Epic Story of a Pastry Chef")],
            columnTypes: [.text(rawType: "TEXT")],
            foreignKeys: [:]
        )
        #expect(try node(root, "description").scalar == .string("A Epic Story of a Pastry Chef"))
    }

    @Test("A foreign key column becomes an expandable node carrying its value")
    func marksForeignKeys() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["language_id"],
            values: [.text("1")],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: ["language_id": reference(column: "language_id")]
        )
        let node = try node(root, "language_id")
        #expect(node.foreignKey == reference(column: "language_id"))
        #expect(node.scalar == .number("1"))
    }

    @Test("A NULL foreign key still reports its reference, so the row can say there is none")
    func marksNullForeignKeys() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["original_language_id"],
            values: [.null],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: ["original_language_id": reference(column: "original_language_id")]
        )
        let node = try node(root, "original_language_id")
        #expect(node.foreignKey != nil)
        #expect(node.scalar == .null)
    }

    @Test("A foreign key column is a key first, whatever its text looks like")
    func foreignKeyBeatsDocumentParsing() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["ref"],
            values: [.text("{\"a\": 1}")],
            columnTypes: [.json(rawType: "JSON")],
            foreignKeys: ["ref": reference(column: "ref")]
        )
        let node = try node(root, "ref")
        #expect(node.foreignKey != nil)
        #expect(node.isContainer == false)
    }

    @Test("A document past the scan cap stays a string")
    func leavesOversizedDocumentsAlone() throws {
        let oversized = "[" + String(repeating: "1,", count: JSONRowNodeBuilder.maxScannedDocumentLength) + "1]"
        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text(oversized)],
            columnTypes: [.json(rawType: "JSON")],
            foreignKeys: [:]
        )
        #expect(try node(root, "payload").isContainer == false)
    }

    @Test("Broken JSON stays a string rather than becoming a partial tree")
    func leavesBrokenDocumentsAlone() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text("{\"a\": 1,}")],
            columnTypes: [.json(rawType: "JSON")],
            foreignKeys: [:]
        )
        #expect(try node(root, "payload").scalar == .string("{\"a\": 1,}"))
    }

    @Test("A document's escapes and nested keys are decoded")
    func decodesDocumentStrings() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["payload"],
            values: [.text(#"{"a\u0041": "line\nbreak"}"#)],
            columnTypes: [.json(rawType: "JSON")],
            foreignKeys: [:]
        )
        let payload = try node(root, "payload")
        #expect(payload.children.first?.key == .name("aA"))
        #expect(payload.children.first?.scalar == .string("line\nbreak"))
    }

    @Test("Two columns with the same label get their own nodes")
    func separatesDuplicateColumnLabels() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["id", "name", "id"],
            values: [.text("1"), .text("Album"), .text("7")],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .integer(rawType: "INT")],
            foreignKeys: [:]
        )

        let paths = Set(root.children.map(\.path))
        #expect(paths.count == root.children.count)
        #expect(root.children.map(\.key) == [.name("id"), .name("name"), .name("id")])
        #expect(root.children[0].scalar == .number("1"))
        #expect(root.children[2].scalar == .number("7"))
    }

    @Test("A row with fewer values than columns reads the missing ones as NULL")
    func toleratesShortRows() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["a", "b"],
            values: [.text("1")],
            columnTypes: [.integer(rawType: "INT")],
            foreignKeys: [:]
        )
        #expect(try node(root, "b").scalar == .null)
    }

    /// `42`, `true`, `null` and `"text"` are whole JSON documents, and a JSON column is allowed to
    /// hold one. Handing them back to the column-type path printed the number as a string and left
    /// the string literal's own quotes inside the printed quotes.
    @Test("A JSON column holding a top-level scalar keeps that scalar's kind")
    func keepsJsonScalarDocuments() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["count", "flag", "missing", "label"],
            values: [.text("42"), .text("true"), .text("null"), .text("\"ready\"")],
            columnTypes: [
                .json(rawType: "JSON"),
                .json(rawType: "JSON"),
                .json(rawType: "JSON"),
                .json(rawType: "JSON"),
            ],
            foreignKeys: [:]
        )

        #expect(try node(root, "count").scalar == .number("42"))
        #expect(try node(root, "flag").scalar == .bool(true))
        #expect(try node(root, "missing").scalar == .null)
        #expect(try node(root, "label").scalar == .string("ready"))
    }

    @Test("A text column holding a bare number stays a string, because it is not a document")
    func leavesNonJsonTextAlone() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["note"],
            values: [.text("42")],
            columnTypes: [.text(rawType: "VARCHAR")],
            foreignKeys: [:]
        )
        #expect(try node(root, "note").scalar == .string("42"))
    }

    /// `JsonSyntaxParser` highlights, it does not validate: it drops the backslash from an unknown
    /// escape and reads a leading zero as a number. A JSON column the engine never validated can
    /// hold either, and retyping one would show the reader something the cell does not say.
    @Test("A JSON column holding text that is not strictly valid JSON stays the text it holds")
    func refusesInvalidJsonScalars() throws {
        let root = JSONRowNodeBuilder.build(
            columns: ["escape", "leadingZero", "negativeZero"],
            values: [.text("\"\\q\""), .text("01"), .text("-01")],
            columnTypes: [.json(rawType: "JSON"), .json(rawType: "JSON"), .json(rawType: "JSON")],
            foreignKeys: [:]
        )

        #expect(try node(root, "escape").scalar == .string("\"\\q\""))
        #expect(try node(root, "leadingZero").scalar == .string("01"))
        #expect(try node(root, "negativeZero").scalar == .string("-01"))
    }
}
