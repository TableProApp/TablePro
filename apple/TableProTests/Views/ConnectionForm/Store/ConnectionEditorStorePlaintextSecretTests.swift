//
//  ConnectionEditorStorePlaintextSecretTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

// A record an unfinished Keychain migration left with a secure value in plain text.
@MainActor
struct ConnectionEditorStorePlaintextSecretTests {
    private let fieldId = "esApiKey"

    private func elasticsearch(apiKey: String) -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Search",
            host: "es.example.com",
            port: 9_200,
            username: "elastic",
            type: .elasticsearch
        )
        connection.additionalFields["esAuthMethod"] = "apiKey"
        connection.additionalFields[fieldId] = apiKey
        return connection
    }

    @Test("A key typed over a plain-text one is the one in the Keychain, and the record keeps no copy")
    func replacedPlaintextSecretLeavesTheRecord() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = elasticsearch(apiKey: "plain-old")
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.fieldValues[fieldId] == "plain-old")

        store.setFieldValue("typed-new", for: fieldId)
        #expect(store.testRecord(testId: UUID()).additionalFields[fieldId] == nil)
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.additionalFields[fieldId] == nil)
        #expect(fixture.storage.loadPluginSecureField(fieldId: fieldId, for: connection.id) == "typed-new")
    }

    @Test("An unrelated Save moves a plain-text key the Keychain lacks into it")
    func untouchedPlaintextSecretMovesToTheKeychain() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = elasticsearch(apiKey: "plain-old")
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.name == "Renamed")
        #expect(saved.additionalFields[fieldId] == nil)
        #expect(fixture.storage.loadPluginSecureField(fieldId: fieldId, for: connection.id) == "plain-old")
    }

    @Test("A key the Keychain holds wins over the plain-text copy, which leaves the record")
    func storedSecretWinsOverPlaintext() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let connection = elasticsearch(apiKey: "plain-old")
        fixture.seed([connection])
        fixture.storage.savePluginSecureField("stored-key", fieldId: fieldId, for: connection.id)
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.fieldValues[fieldId] == "stored-key")

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.additionalFields[fieldId] == nil)
        #expect(fixture.storage.loadPluginSecureField(fieldId: fieldId, for: connection.id) == "stored-key")
    }

    @Test("A plain-text key whose Keychain item cannot be read stays in the record, as the migration leaves it")
    func plaintextSecretOverAnUnreadableItemStays() throws {
        let keychain = ScopeRecordingKeychain()
        let fixture = try ConnectionEditorStoreFixture(storageKeychain: keychain)
        let connection = elasticsearch(apiKey: "plain-old")
        fixture.seed([connection])
        keychain.makeUnreadable("com.TablePro.plugin.\(fieldId).\(connection.id.uuidString)")
        let store = fixture.makeStore(.edit(connectionId: connection.id))
        #expect(store.draft.fieldValues[fieldId]?.isEmpty != false)

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.name == "Renamed")
        #expect(saved.additionalFields[fieldId] == "plain-old")
    }

    @Test("A plain-text key another writer stored after the editor opened leaves the record for the Keychain")
    func plaintextSecretWrittenElsewhereMoves() throws {
        let fixture = try ConnectionEditorStoreFixture()
        var connection = elasticsearch(apiKey: "")
        connection.additionalFields[fieldId] = nil
        fixture.seed([connection])
        let store = fixture.makeStore(.edit(connectionId: connection.id))

        var elsewhere = try #require(fixture.storage.loadConnection(id: connection.id))
        elsewhere.additionalFields[fieldId] = "plain-elsewhere"
        fixture.seed([elsewhere])

        store.update { $0.name = "Renamed" }
        _ = try store.save().get()

        let saved = try #require(fixture.storage.loadConnection(id: connection.id))
        #expect(saved.additionalFields[fieldId] == nil)
        #expect(fixture.storage.loadPluginSecureField(fieldId: fieldId, for: connection.id) == "plain-elsewhere")
    }
}
