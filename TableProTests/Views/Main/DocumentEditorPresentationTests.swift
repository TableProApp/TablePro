//
//  DocumentEditorPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DocumentEditorPresentationTests {
    private let edit = DocumentEditorRequest.Kind.edit(locator: "1")

    @Test("An insert starts editable and an edit starts by loading")
    func initialPhase() {
        #expect(DocumentEditorPresentation.initialPhase(for: .insert) == .editing)
        #expect(DocumentEditorPresentation.initialPhase(for: edit) == .loading)
    }

    @Test("While a write is on its way the text is read only and the sheet cannot be closed")
    func savingLocksTheSheet() {
        for kind in [DocumentEditorRequest.Kind.insert, edit] {
            let saving = DocumentEditorPresentation(kind: kind, phase: .saving)
            #expect(!saving.isEditable)
            #expect(!saving.canSave)
            #expect(!saving.canCancel)
            #expect(saving.dismissDisabled)
            #expect(saving.showsEditor)
        }
    }

    @Test("While the document loads there is nothing to edit, and Cancel still works")
    func loading() {
        let loading = DocumentEditorPresentation(kind: edit, phase: .loading)
        #expect(!loading.showsEditor)
        #expect(!loading.isEditable)
        #expect(!loading.showsSave)
        #expect(loading.canCancel)
        #expect(!loading.dismissDisabled)
        #expect(loading.message == nil)
    }

    @Test("A document that is gone, or failed to load, offers only Close with the reason")
    func noDocument() {
        let missing = DocumentEditorPresentation(kind: edit, phase: .missing)
        #expect(!missing.showsEditor)
        #expect(!missing.showsSave)
        #expect(missing.cancelTitle == String(localized: "Close"))
        #expect(missing.message != nil)
        let failed = DocumentEditorPresentation(kind: edit, phase: .loadFailed("refused"))
        #expect(failed.message == "refused")
        #expect(!failed.showsSave)
    }

    @Test("Editing allows saving under the title and button of its kind")
    func editing() {
        let insert = DocumentEditorPresentation(kind: .insert, phase: .editing)
        #expect(insert.isEditable && insert.canSave && insert.canCancel)
        #expect(insert.title == String(localized: "Insert Document"))
        #expect(insert.saveTitle == String(localized: "Insert"))
        let editing = DocumentEditorPresentation(kind: edit, phase: .editing)
        #expect(editing.title == String(localized: "Edit Document"))
        #expect(editing.saveTitle == String(localized: "Save"))
        #expect(editing.hint != insert.hint)
    }
}

@MainActor
struct DocumentEditingOperationTests {
    @Test("An insert writes the text as a new document")
    func insert() throws {
        #expect(try DocumentEditing.operation(for: .insert, text: "{}", original: nil) == .insert(document: "{}"))
    }

    @Test("An edit replaces the document it was read as")
    func edit() throws {
        let operation = try DocumentEditing.operation(for: .edit(locator: "1"), text: "{\"a\":2}", original: "{\"a\":1}")
        #expect(operation == .replace(original: "{\"a\":1}", edited: "{\"a\":2}"))
    }

    @Test("An edit whose document never loaded is refused, never written as a new document")
    func editWithoutOriginal() {
        #expect(throws: DocumentEditingError.documentNotLoaded) {
            try DocumentEditing.operation(for: .edit(locator: "1"), text: "{}", original: nil)
        }
    }

    @Test("History names the operation by its kind")
    func operationDescription() {
        #expect(DocumentEditing.operationDescription(for: .insert) == String(localized: "Insert Document"))
        #expect(DocumentEditing.operationDescription(for: .edit(locator: "1")) == String(localized: "Edit Document"))
    }
}
