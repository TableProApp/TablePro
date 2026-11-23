//
//  ConnectionEditorQuitTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorQuitTests {
    private func postgres(name: String) -> DatabaseConnection {
        DatabaseConnection(name: name, host: "db.example.com", port: 5_432, database: "orders", username: "app", type: .postgresql)
    }

    private func editor(
        _ fixture: ConnectionEditorStoreFixture,
        _ connection: DatabaseConnection,
        host: String? = nil
    ) -> ConnectionEditorWindowController {
        let controller = ConnectionEditorWindowController(
            store: fixture.makeStore(.edit(connectionId: connection.id)),
            frameAutosaveName: nil
        )
        if let host {
            controller.store.update { $0.host = host }
        }
        return controller
    }

    @Test("An editor with nothing to save is not asked, and the quit goes on")
    func cleanEditorIsNotAsked() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let clean = editor(fixture, connection)
        defer { clean.close() }
        var asked: [String] = []

        let approved = ConnectionEditorWindowController.prepareToTerminate([clean]) { _, prompt in
            asked.append(prompt.connectionName)
            return .cancel
        }

        #expect(approved)
        #expect(asked.isEmpty)
    }

    @Test("Cancel stops the quit and writes nothing")
    func cancelStopsTheQuit() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let edited = editor(fixture, connection, host: "replica.example.com")
        defer { edited.close() }

        let approved = ConnectionEditorWindowController.prepareToTerminate([edited]) { _, _ in .cancel }

        #expect(!approved)
        #expect(!edited.store.isClosing)
        #expect(fixture.storage.loadConnection(id: connection.id)?.host == "db.example.com")
    }

    @Test("Don't Save lets the quit go on and writes nothing")
    func dontSaveQuits() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let edited = editor(fixture, connection, host: "replica.example.com")
        defer { edited.close() }

        let approved = ConnectionEditorWindowController.prepareToTerminate([edited]) { _, _ in .dontSave }

        #expect(approved)
        #expect(fixture.storage.loadConnection(id: connection.id)?.host == "db.example.com")
    }

    @Test("Save writes the edits without connecting, closes the editor and lets the quit go on")
    func saveQuits() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let edited = editor(fixture, connection, host: "replica.example.com")
        var prompts: [ConnectionEditorSavePrompt] = []

        let approved = ConnectionEditorWindowController.prepareToTerminate([edited]) { _, prompt in
            prompts.append(prompt)
            return .save
        }

        #expect(approved)
        #expect(prompts == [ConnectionEditorSavePrompt(connectionName: "Orders")])
        #expect(edited.store.isClosing)
        #expect(fixture.storage.loadConnection(id: connection.id)?.host == "replica.example.com")
    }

    @Test("A Save that fails stops the quit and leaves the editor on the issue")
    func failedSaveStopsTheQuit() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = postgres(name: "Orders")
        fixture.seed([connection])
        let edited = editor(fixture, connection, host: "replica.example.com")
        defer { edited.close() }
        edited.store.setPort("99999")
        edited.store.selectedFacet = .appearance

        let approved = ConnectionEditorWindowController.prepareToTerminate([edited]) { _, _ in .save }

        #expect(!approved)
        #expect(!edited.store.isClosing)
        #expect(edited.store.selectedFacet == .general)
        #expect(edited.store.revealedIssue(for: .builtIn(.port)) != nil)
        #expect(fixture.storage.loadConnection(id: connection.id)?.port == 5_432)
    }

    @Test("Editors are asked one at a time, and a Cancel stops before the next is asked")
    func oneEditorAtATime() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let orders = postgres(name: "Orders")
        let billing = postgres(name: "Billing")
        let reports = postgres(name: "Reports")
        fixture.seed([orders, billing, reports])
        let first = editor(fixture, orders, host: "one.example.com")
        let second = editor(fixture, billing, host: "two.example.com")
        let third = editor(fixture, reports, host: "three.example.com")
        defer {
            first.close()
            second.close()
            third.close()
        }
        var asked: [String] = []

        let approved = ConnectionEditorWindowController.prepareToTerminate([first, second, third]) { _, prompt in
            asked.append(prompt.connectionName)
            return prompt.connectionName == "Orders" ? .dontSave : .cancel
        }

        #expect(!approved)
        #expect(asked == ["Orders", "Billing"])
        #expect(fixture.storage.loadConnection(id: reports.id)?.host == "db.example.com")
    }
}
