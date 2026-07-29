//
//  CSVDocumentUndoTests.swift
//  TableProTests
//
//  Tests CSVDocument (compiled via symlink from Plugins/CSVInspectorPlugin/).
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@MainActor
@Suite("CSVDocument undo naming")
struct CSVDocumentUndoTests {
    private func makeDocument(_ contents: String) throws -> CSVDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        try contents.data(using: .utf8)!.write(to: url)
        let document = CSVDocument()
        try document.read(from: url, ofType: "public.comma-separated-values-text")
        try? FileManager.default.removeItem(at: url)
        return document
    }

    @Test("Insert Row keeps its name through undo and redo")
    func insertRowNaming() throws {
        let document = try makeDocument("a,b\n1,2\n")
        document.insertRow(at: 0)
        #expect(document.undoManager?.undoActionName == "Insert Row")
        document.undoManager?.undo()
        #expect(document.undoManager?.redoActionName == "Insert Row")
        document.undoManager?.redo()
        #expect(document.undoManager?.undoActionName == "Insert Row")
    }

    @Test("Delete Rows keeps its name through undo")
    func deleteRowsNaming() throws {
        let document = try makeDocument("a,b\n1,2\n3,4\n5,6\n")
        document.removeRows(at: IndexSet([0, 1]))
        #expect(document.undoManager?.undoActionName == "Delete Rows")
        document.undoManager?.undo()
        #expect(document.undoManager?.redoActionName == "Delete Rows")
    }

    @Test("Add Row keeps its name through undo and redo")
    func addRowNaming() throws {
        let document = try makeDocument("a,b\n1,2\n")
        document.appendRow()
        #expect(document.undoManager?.undoActionName == "Add Row")
        document.undoManager?.undo()
        #expect(document.undoManager?.redoActionName == "Add Row")
    }
}
