//
//  ConnectionDraftRetypeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionDraftRetypeTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func mysqlDraft() -> ConnectionDraft {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.name = "Shop"
        draft.environment = .staging
        draft.host = "db.example.com"
        draft.setPort("3307", traits: mysql)
        draft.database = "shop"
        draft.credentials.username = "admin"
        draft.credentials.password = "hunter2"
        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion.example.com"
        draft.selectSSLMode(.required)
        draft.ssl.clientCertPath = "/client.pem"
        draft.ssl.clientKeyPath = "/client.key"
        draft.appearance.color = .blue
        return draft
    }

    @Test("MySQL to MariaDB keeps host, a custom port, the database, the credentials, SSH and SSL")
    func networkRetypeKeepsWhatTheNewTypeSupports() {
        let proposal = mysqlDraft().retyped(to: traits(.mariadb), from: traits(.mysql))
        let result = proposal.result
        #expect(result.type == .mariadb)
        #expect(result.name == "Shop")
        #expect(result.environment == .staging)
        #expect(result.host == "db.example.com")
        #expect(result.portText == "3307")
        #expect(result.database == "shop")
        #expect(result.credentials.username == "admin")
        #expect(result.credentials.password == "hunter2")
        #expect(result.transport == .ssh)
        #expect(result.ssh.host == "bastion.example.com")
        #expect(result.ssl.mode == .required)
        #expect(result.ssl.clientCertPath == "/client.pem")
        #expect(result.appearance.color == .blue)
        #expect(!proposal.needsConfirmation)
    }

    @Test("A port equal to the old type's default becomes the new type's default")
    func defaultPortFollowsTheType() {
        let mysql = traits(.mysql)
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        #expect(draft.portText == String(mysql.defaultPort))
        draft.retype(to: postgres, from: mysql)
        #expect(draft.portText == String(postgres.defaultPort))
    }

    @Test("A file type drops the password prompt and the credential profile, and says so")
    func fileTypeDropsAuthentication() {
        var draft = mysqlDraft()
        draft.setPasswordPrompt(true, traits: traits(.mysql))
        draft.setCredentialMode(.profile(id: UUID()))
        let proposal = draft.retyped(to: traits(.sqlite), from: traits(.mysql))
        let result = proposal.result
        #expect(!result.credentials.promptsForPassword)
        #expect(result.credentials.mode == .inline)
        #expect(result.credentials.password.isEmpty)
        #expect(result.database.isEmpty)
        #expect(result.transport == nil)
        #expect(!ConnectionEditorEngine.effectivePromptForPassword(result, traits(.sqlite)))
        #expect(proposal.needsConfirmation)
        #expect(proposal.dropped.contains(String(localized: "Credential Profile")))
        #expect(proposal.dropped.contains(String(localized: "Database")))
        #expect(proposal.dropped.contains(ConnectionTunnelKind.ssh.displayName))
    }

    @Test("Every plugin default of the new type is seeded, in every section")
    func newTypeDefaultsAreSeeded() {
        let duckdb = traits(.duckdb)
        let draft = mysqlDraft().retyped(to: duckdb, from: traits(.mysql)).result
        for field in duckdb.fields {
            guard let defaultValue = field.defaultValue else { continue }
            #expect(draft.fieldValues[field.id] == defaultValue, "\(field.id)")
        }
    }

    @Test("A new connection seeds the defaults of every section once")
    func newDraftSeedsEverySection() {
        let duckdb = traits(.duckdb)
        let draft = ConnectionDraft.new(type: .duckdb, traits: duckdb)
        for field in duckdb.fields {
            guard let defaultValue = field.defaultValue else { continue }
            #expect(draft.fieldValues[field.id] == defaultValue, "\(field.id)")
        }
    }

    @Test("A chosen SSL mode the new type's tunnel refuses falls back to the type's own resolution")
    func refusedSSLModeIsNotKept() {
        var mssql = traits(.mssql)
        mssql.ssl.modesThroughTunnel = [.disabled, .preferred, .required]
        var draft = mysqlDraft()
        draft.selectSSLMode(.verifyIdentity)
        let result = draft.retyped(to: mssql, from: traits(.mysql)).result
        #expect(result.transport == .ssh)
        #expect(result.ssl.mode != .verifyIdentity)
    }
}
