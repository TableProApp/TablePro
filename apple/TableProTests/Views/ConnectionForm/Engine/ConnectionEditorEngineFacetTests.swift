//
//  ConnectionEditorEngineFacetTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineFacetTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func facets(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext = EditorContext())
        -> [ConnectionFacet] {
        ConnectionEditorEngine.layout(draft, traits, context).facetIDs
    }

    @Test("Facets keep their order, and the ones that always apply are always there")
    func alwaysPresentFacets() {
        for type in DatabaseType.allKnownTypes {
            let traits = traits(type)
            let facets = facets(ConnectionDraft.new(type: type, traits: traits), traits)
            for always in [ConnectionFacet.general, .appearance, .safeMode, .aiAndMCP, .startup, .advanced] {
                #expect(facets.contains(always), "\(type.rawValue) lacks \(always)")
            }
            let order = ConnectionFacet.allCases.filter { facets.contains($0) }
            #expect(order == facets, "\(type.rawValue)")
        }
    }

    @Test("PostgreSQL shows transports and SSL; over a socket folder it shows neither")
    func postgresFacets() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        #expect(facets(draft, postgres).contains(.sshAndProxies))
        #expect(facets(draft, postgres).contains(.sslTLS))

        draft.selectEndpoint(.localSocket)
        #expect(!facets(draft, postgres).contains(.sshAndProxies))
        #expect(!facets(draft, postgres).contains(.sslTLS))
    }

    @Test("SQLite offers Remote File under its own title and no SSL")
    func sqliteFacets() throws {
        let sqlite = traits(.sqlite)
        let draft = ConnectionDraft.new(type: .sqlite, traits: sqlite)
        let layout = ConnectionEditorEngine.layout(draft, sqlite, EditorContext())
        let transport = try #require(layout.facet(.sshAndProxies))
        #expect(transport.title == String(localized: "Remote File"))
        #expect(layout.facet(.sslTLS) == nil)
        #expect(layout.contains(.builtIn(.databaseFile)))
        #expect(!layout.contains(.builtIn(.password)))
    }

    @Test("A credential profile hides the inline username and password rows")
    func profileHidesInlineCredentials() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        var layout = ConnectionEditorEngine.layout(draft, mysql, EditorContext())
        #expect(layout.contains(.builtIn(.username)))
        #expect(layout.contains(.builtIn(.password)))
        draft.setCredentialMode(.profile(id: UUID()))
        layout = ConnectionEditorEngine.layout(draft, mysql, EditorContext())
        #expect(layout.contains(.builtIn(.credentialProfile)))
        #expect(!layout.contains(.builtIn(.username)))
        #expect(!layout.contains(.builtIn(.password)))
    }

    @Test("AI Policy is always shown, AI rules follow the AI setting, Local only follows Sync")
    func contextDrivenSections() {
        let mysql = traits(.mysql)
        let draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        var context = EditorContext()
        var layout = ConnectionEditorEngine.layout(draft, mysql, context)
        #expect(layout.contains(.builtIn(.externalAccess)))
        #expect(layout.contains(.builtIn(.aiPolicy)))
        #expect(!layout.contains(.builtIn(.aiRules)))
        #expect(!layout.contains(.builtIn(.localOnly)))
        context.aiEnabled = true
        context.syncEnabled = true
        layout = ConnectionEditorEngine.layout(draft, mysql, context)
        #expect(layout.contains(.builtIn(.aiPolicy)))
        #expect(layout.contains(.builtIn(.aiRules)))
        #expect(layout.contains(.builtIn(.localOnly)))
    }

    @Test("Socket clears the transport in the same edit")
    func socketClearsTransport() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.selectTransport(.ssh)
        draft.sshForwardUnixSocketPath = "/var/run/mysqld.sock"
        draft.selectEndpoint(.localSocket)
        #expect(draft.transport == nil)
        #expect(draft.sshForwardUnixSocketPath.isEmpty)
    }

    @Test("Ask Every Time empties the password and turns off a toggle that supplies it")
    func promptClearsPasswordSuppliers() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.credentials.password = "hunter2"
        if postgres.field("usePgpass") != nil {
            draft.setFieldValue("true", for: "usePgpass")
        }
        draft.setPasswordPrompt(true, traits: postgres)
        #expect(draft.credentials.password.isEmpty)
        #expect(draft.fieldValues["usePgpass"] != "true")
    }
}
