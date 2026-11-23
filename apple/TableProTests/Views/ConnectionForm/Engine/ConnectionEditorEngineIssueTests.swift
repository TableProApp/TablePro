//
//  ConnectionEditorEngineIssueTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineIssueTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func issues(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext = EditorContext())
        -> [FieldIssue] {
        ConnectionEditorEngine.issues(draft, traits, context)
    }

    // Every type, every bad value at once, with each transport and a socket forward: no issue may point at a row the
    // layout hides or shows disabled.
    @Test("Every issue names a row the layout shows enabled, for every registered type")
    func everyIssueRowIsVisible() {
        for type in DatabaseType.allKnownTypes {
            let traits = traits(type)
            var draft = ConnectionDraft.new(type: type, traits: traits)
            draft.name = ""
            draft.database = ""
            draft.portText = "99999"
            draft.options.connectTimeoutSeconds = 0
            draft.options.queryTimeoutSeconds = -5
            draft.options.binaryInlineLimitKilobytes = 0
            draft.options.scriptTimeoutSeconds = 0
            draft.ssl.clientCertPath = "/cert.pem"
            draft.ssl.clientKeyPath = ""
            for field in traits.fields where field.isRequired {
                draft.fieldValues[field.id] = ""
            }
            for transport in ConnectionEditorEngine.availableTransports(draft, traits) {
                var withTransport = draft
                withTransport.selectTransport(transport)
                var variants = [withTransport]
                if transport == .ssh {
                    var forwarding = withTransport
                    forwarding.sshForwardUnixSocketPath = "/var/run/db.sock"
                    variants.append(forwarding)
                }
                for variant in variants {
                    let layout = ConnectionEditorEngine.layout(variant, traits, EditorContext())
                    for issue in ConnectionEditorEngine.issues(variant, traits, EditorContext(), layout: layout) {
                        #expect(layout.facet(issue.facet)?.contains(issue.row) == true, "\(type.rawValue): \(issue.message)")
                        #expect(!layout.disabledRows.contains(issue.row), "\(type.rawValue): \(issue.message) on a disabled row")
                    }
                }
            }
        }
    }

    @Test("A binary limit left invalid by MySQL blocks nothing once the type has no such row")
    func hiddenBinaryLimitDoesNotBlock() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.name = "Shop"
        draft.options.binaryInlineLimitKilobytes = 0
        #expect(issues(draft, mysql).contains { $0.row == .builtIn(.binaryInlineLimit) } == mysql.supportsBinaryInlineLimit)

        let postgres = traits(.postgresql)
        draft.retype(to: postgres, from: mysql)
        #expect(!issues(draft, postgres).contains { $0.row == .builtIn(.binaryInlineLimit) })
    }

    @Test("A client certificate without a key blocks nothing while SSL Mode is Disabled")
    func hiddenClientKeyDoesNotBlock() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.name = "Orders"
        draft.selectSSLMode(.required)
        draft.ssl.clientCertPath = "/client.pem"
        #expect(issues(draft, postgres).contains { $0.row == .builtIn(.sslClientKey) })

        draft.selectSSLMode(.disabled)
        #expect(!issues(draft, postgres).contains { $0.row == .builtIn(.sslClientKey) })
    }

    @Test("An https host list with SSL Mode Disabled points at SSL Mode in SSL/TLS")
    func httpsHostListPointsAtSSLMode() throws {
        let elastic = traits(.elasticsearch)
        let hostList = try #require(elastic.fields.endpointHostList)
        var draft = ConnectionDraft.new(type: .elasticsearch, traits: elastic)
        draft.name = "Search"
        draft.selectSSLMode(.disabled)
        draft.fieldValues[hostList.id] = "https://es.example.com:9200"

        let issue = try #require(issues(draft, elastic).first { $0.message.contains("https://es.example.com:9200") })
        #expect(issue.row == .builtIn(.sslMode))
        #expect(issue.facet == .sslTLS)
    }

    @Test("A required field a linked credential profile hides does not block Save")
    func profileHiddenRequiredFieldDoesNotBlock() {
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "Probe"))
        traits.fields = [
            ConnectionField(
                id: "apiKey",
                label: "API Key",
                required: true,
                secure: true,
                section: .authentication,
                hidesPassword: true
            ).withHidesUsername(true)
        ]
        let profile = CredentialProfile(name: "Shared", secureFieldIds: [])
        var context = EditorContext()
        context.credentialProfiles = [profile]
        var draft = ConnectionDraft.new(type: traits.type, traits: traits)
        draft.name = "Probe"
        #expect(issues(draft, traits, context).contains { $0.row == .plugin(fieldID: "apiKey") })

        draft.setCredentialMode(.profile(id: profile.id))
        #expect(!issues(draft, traits, context).contains { $0.row == .plugin(fieldID: "apiKey") })
    }

    @Test("The port is a trimmed whole number from 1 to 65535, and empty means the default")
    func portParsing() {
        #expect(ConnectionEditorEngine.parsePort("15432 ") == 15_432)
        #expect(ConnectionEditorEngine.parsePort(" 15432") == 15_432)
        #expect(ConnectionEditorEngine.parsePort("99999") == nil)
        #expect(ConnectionEditorEngine.parsePort("-1") == nil)
        #expect(ConnectionEditorEngine.parsePort("0") == nil)
        #expect(ConnectionEditorEngine.parsePort("33o6") == nil)
        #expect(ConnectionEditorEngine.parsePort("abc") == nil)
        #expect(ConnectionEditorEngine.portIssue("") == nil)
        #expect(ConnectionEditorEngine.portIssue("15432 ") == nil)
        #expect(ConnectionEditorEngine.portIssue("99999") != nil)
        #expect(ConnectionEditorEngine.portIssue("33o6") != nil)
    }

    @Test("An unparsable port is an issue on the Port row and is never saved as the default")
    func badPortBlocksSave() throws {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.name = "Orders"
        draft.setPort("33o6", traits: postgres)
        let issue = try #require(issues(draft, postgres).first { $0.row == .builtIn(.port) })
        #expect(issue.blocksSave)

        draft.setPort("15432 ", traits: postgres)
        #expect(!issues(draft, postgres).contains { $0.row == .builtIn(.port) })
        let edits = ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext())
        #expect(edits.port == 15_432)
    }

    @Test("Port blocks nothing while the SSH tunnel forwards to a socket and the field is off")
    func portIsUnusedWhileForwardingToASocket() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.name = "Orders"
        draft.setPort("99999", traits: postgres)
        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion.example.com"
        #expect(issues(draft, postgres).contains { $0.row == .builtIn(.port) })

        draft.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"
        #expect(!issues(draft, postgres).contains { $0.row == .builtIn(.port) })
        let layout = ConnectionEditorEngine.layout(draft, postgres, EditorContext())
        #expect(layout.contains(.builtIn(.port)))
        #expect(!layout.isEnabled(.builtIn(.port)))
    }

    @Test("A file on an SSH server needs no local database file, and General says the local path is unused")
    func remoteFileNeedsNoLocalFile() throws {
        let sqlite = traits(.sqlite)
        var draft = ConnectionDraft.new(type: .sqlite, traits: sqlite)
        draft.name = "Remote"
        draft.database = ""
        #expect(issues(draft, sqlite).contains { $0.row == .builtIn(.databaseFile) })

        draft.selectTransport(.remoteFile)
        draft.ssh.host = "prod-1"
        draft.ssh.username = "deploy"
        draft.ssh.remoteFilePath = "/srv/app.db"
        #expect(issues(draft, sqlite).isEmpty)
        let layout = ConnectionEditorEngine.layout(draft, sqlite, EditorContext())
        let section = try #require(layout.facet(.general)?.section(containing: .builtIn(.databaseFile)))
        #expect(section.footer != nil)
        #expect(!layout.isEnabled(.builtIn(.databaseFile)))
    }

    @Test("An empty name is no issue: Save and Test use the suggested name")
    func emptyNameBlocksNothing() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.name = ""
        draft.host = "db.example.com"
        #expect(!issues(draft, postgres).contains { $0.row == .builtIn(.name) })
        let edits = ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext())
        #expect(edits.name == "db.example.com")
    }

    @Test("SSL modes the driver refuses through a tunnel are not offered and block Save")
    func sslModesThroughTunnel() throws {
        var traits = traits(.postgresql)
        traits.ssl.supportedModes = SSLMode.allCases
        traits.ssl.modesThroughTunnel = [.disabled, .preferred, .required]
        var draft = ConnectionDraft.new(type: .postgresql, traits: traits)
        draft.name = "Orders"
        draft.selectSSLMode(.verifyIdentity)
        draft.ssl.caCertPath = "/ca.pem"
        #expect(ConnectionEditorEngine.offeredSSLModes(draft, traits).contains(.verifyIdentity))

        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion.example.com"
        #expect(!ConnectionEditorEngine.offeredSSLModes(draft, traits).contains(.verifyIdentity))
        let issue = try #require(issues(draft, traits).first { $0.row == .builtIn(.sslMode) })
        #expect(issue.facet == .sslTLS)
    }

    @Test("A jump host that is not valid names its own row")
    func jumpHostIssueNamesItsRow() throws {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.name = "Shop"
        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion"
        let id = draft.addJumpHost()
        let issue = try #require(issues(draft, mysql).first { $0.row == .builtIn(.jumpHost(id)) })
        #expect(issue.facet == .sshAndProxies)
    }
}
