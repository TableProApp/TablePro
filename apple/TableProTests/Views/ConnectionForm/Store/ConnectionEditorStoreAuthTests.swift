//
//  ConnectionEditorStoreAuthTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreAuthTests {
    private func connection(
        source: PasswordSource?,
        type: DatabaseType = .mysql,
        configure: (inout DatabaseConnection) -> Void = { _ in }
    ) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(type: type)
        connection.username = "app"
        connection.passwordSource = source
        configure(&connection)
        return connection
    }

    private func editing(_ connection: DatabaseConnection, in fixture: ConnectionEditorStoreFixture) -> ConnectionEditorStore {
        fixture.seed([connection])
        return fixture.makeStore(.edit(connectionId: connection.id))
    }

    @Test("The form knows where a connection's password comes from")
    func loadsThePasswordSource() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let source = PasswordSource.command(shell: "op read op://vault/db/password")
        let store = editing(connection(source: source), in: fixture)

        #expect(store.draft.credentials.passwordSource == source)
        #expect(ConnectionEditorEngine.passwordSourceInUse(store.draft, store.traits) == source)
        #expect(store.layout.contains(.builtIn(.passwordSource)))
    }

    @Test("A prompt or a linked profile overrides the connection's own source")
    func promptAndProfileOverrideTheSource() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = editing(connection(source: .env(variable: "DB_PASSWORD")), in: fixture)

        store.setPasswordPrompt(true)
        #expect(ConnectionEditorEngine.passwordSourceInUse(store.draft, store.traits) == nil)
        #expect(!store.layout.contains(.builtIn(.passwordSource)))

        store.setPasswordPrompt(false)
        store.setCredentialMode(.profile(id: UUID()))
        #expect(ConnectionEditorEngine.passwordSourceInUse(store.draft, store.traits) == nil)
    }

    @Test("Saving a source-backed connection as a profile keeps the source")
    func promotionKeepsATrustedSource() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let source = PasswordSource.file(path: "~/.secrets/db")
        let store = editing(connection(source: source), in: fixture)

        #expect(fixture.storage.storeIsTrusted)
        #expect(store.credentialProfileFromCurrentCredentials().passwordMode == .source(source))
    }

    @Test("A source from a connections file something else changed becomes a prompt, never a profile source")
    func promotionDropsAnUntrustedSource() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let planted = connection(source: .command(shell: "echo owned"))
        fixture.seed([planted])
        let fileURL = fixture.directory.appendingPathComponent("connections.json")
        var data = try Data(contentsOf: fileURL)
        data.append(contentsOf: Array(" ".utf8))
        try data.write(to: fileURL)
        fixture.storage.invalidateCache()

        let store = fixture.makeStore(.edit(connectionId: planted.id))
        #expect(store.draft.credentials.passwordSource != nil)
        #expect(!fixture.storage.storeIsTrusted)
        #expect(store.credentialProfileFromCurrentCredentials().passwordMode == .prompt)
    }

    // ~/.pgpass is a PostgreSQL toggle, so the promotion is checked on a type that declares it.
    @Test("Saving a ~/.pgpass connection as a profile keeps ~/.pgpass")
    func promotionKeepsPgpass() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = editing(connection(source: nil, type: .postgresql), in: fixture)
        #expect(store.traits.field(ConnectionEditorEngine.pgpassFieldId) != nil)
        store.setFieldValue("true", for: ConnectionEditorEngine.pgpassFieldId)

        #expect(store.credentialProfileFromCurrentCredentials().passwordMode == .pgpass)
    }

    @Test("Test Connection asks for the password when Prompt for password is on")
    func testConnectionCarriesThePromptFlag() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: nil, parsedURL: nil))
        store.setPasswordPrompt(true)

        let tested = store.testRecord(testId: UUID())

        #expect(tested.promptForPassword)
        #expect(ConnectionCredentialResolver.promptsForPassword(tested))
    }

    @Test("Test Connection runs the connection's source, not a Keychain password left beside it")
    func testConnectionUsesTheSource() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let source = PasswordSource.env(variable: "DB_PASSWORD")
        let stored = connection(source: source)
        fixture.seed([stored])
        #expect(fixture.storage.savePassword("stale", for: stored.id))
        let store = fixture.makeStore(.edit(connectionId: stored.id))

        #expect(store.draft.credentials.password == "stale")
        #expect(store.testRecord(testId: UUID()).passwordSource == source)
    }

    @Test("A connection with only a source can still be saved as a profile")
    func sourceAloneIsPromotable() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = editing(connection(source: .env(variable: "REDIS_PASSWORD")) { $0.username = "" }, in: fixture)

        #expect(store.hasPromotableCredentials)
    }
}
