//
//  AdvancedPaneExtensionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct AdvancedPaneExtensionTests {
    private let vec = LoadableExtension(path: "/opt/homebrew/lib/vec0.dylib")
    private let spatialite = LoadableExtension(path: "/opt/homebrew/lib/mod_spatialite.dylib")

    private func coordinator(editing connection: DatabaseConnection) throws -> ConnectionFormCoordinator {
        try #require(
            PluginManager.shared.additionalConnectionFields(for: .sqlite)
                .contains { $0.content == .loadableExtensions }
        )
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = .sqlite
        coordinator.advanced.load(from: connection)
        return coordinator
    }

    private func sqlite(with extensions: [LoadableExtension]) -> DatabaseConnection {
        DatabaseConnection(
            name: "Vectors",
            type: .sqlite,
            additionalFields: [LoadableExtensionList.fieldId: LoadableExtensionList.encode(extensions)]
        )
    }

    @Test("The Extensions list is its own section, not a row among the driver options")
    func extensionFieldIsNotADriverRow() throws {
        let form = try coordinator(editing: sqlite(with: []))
        #expect(form.advanced.extensionListField?.id == LoadableExtensionList.fieldId)
        #expect(!form.advanced.advancedFields.contains { $0.id == LoadableExtensionList.fieldId })
    }

    @Test("Saving an imported list untouched approves none of it")
    func untouchedListApprovesNothing() throws {
        let form = try coordinator(editing: sqlite(with: [vec]))
        #expect(form.advanced.initialExtensions == [vec])
        #expect(form.advanced.editedExtensions.isEmpty)
    }

    @Test("Only the files added in this form count as chosen on this Mac")
    func addedFilesAreEdited() throws {
        let form = try coordinator(editing: sqlite(with: [vec]))
        form.advanced.additionalFieldValues[LoadableExtensionList.fieldId] =
            LoadableExtensionList.encode([vec, spatialite])
        #expect(form.advanced.editedExtensions == [spatialite])
    }

    @Test("Changing a file's entry point makes it a new choice")
    func changedEntryPointIsEdited() throws {
        let form = try coordinator(editing: sqlite(with: [vec]))
        let renamed = LoadableExtension(path: vec.path, entryPoint: "sqlite3_vec_init")
        form.advanced.additionalFieldValues[LoadableExtensionList.fieldId] = LoadableExtensionList.encode([renamed])
        #expect(form.advanced.editedExtensions == [renamed])
    }

    @Test("An invalid list blocks saving with the reason")
    func invalidListIsAValidationIssue() throws {
        let form = try coordinator(editing: sqlite(with: []))
        form.advanced.additionalFieldValues[LoadableExtensionList.fieldId] =
            LoadableExtensionList.encode([LoadableExtension(path: "vec0.dylib")])
        #expect(form.advanced.validationIssues.contains { $0.contains("vec0.dylib") })
    }
}
