//
//  ConnectionEditorStoreAdvancedTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreAdvancedTests {
    private let vec = LoadableExtension(path: "/opt/homebrew/lib/vec0.dylib")
    private let spatialite = LoadableExtension(path: "/opt/homebrew/lib/mod_spatialite.dylib")

    private func editing(_ extensions: [LoadableExtension], in fixture: ConnectionEditorStoreFixture) throws
        -> ConnectionEditorStore {
        try #require(
            PluginManager.shared.additionalConnectionFields(for: .sqlite)
                .contains { $0.content == .loadableExtensions }
        )
        let connection = DatabaseConnection(
            name: "Vectors",
            type: .sqlite,
            additionalFields: [LoadableExtensionList.fieldId: LoadableExtensionList.encode(extensions)]
        )
        fixture.seed([connection])
        return fixture.makeStore(.edit(connectionId: connection.id))
    }

    @Test("Saving an imported list untouched approves none of it")
    func untouchedListApprovesNothing() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try editing([vec], in: fixture)
        #expect(try LoadableExtensionList.decode(store.draft.fieldValues[LoadableExtensionList.fieldId]) == [vec])
        #expect(store.editedExtensions.isEmpty)
    }

    @Test("Only the files added in this form count as chosen on this Mac")
    func addedFilesAreEdited() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try editing([vec], in: fixture)
        store.setFieldValue(LoadableExtensionList.encode([vec, spatialite]), for: LoadableExtensionList.fieldId)
        #expect(store.editedExtensions == [spatialite])
    }

    @Test("Changing a file's entry point makes it a new choice")
    func changedEntryPointIsEdited() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = try editing([vec], in: fixture)
        let renamed = LoadableExtension(path: vec.path, entryPoint: "sqlite3_vec_init")
        store.setFieldValue(LoadableExtensionList.encode([renamed]), for: LoadableExtensionList.fieldId)
        #expect(store.editedExtensions == [renamed])
    }

    @Test("A new connection saved Local only has nothing in iCloud Keychain to remove")
    func newLocalOnlyConnectionRemovesNothing() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .mysql, parsedURL: nil))
        store.update { $0.options.localOnly = true }

        #expect(!store.removesSyncedSecretsOnSave)
    }
}
