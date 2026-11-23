//
//  ConnectionEditorEngineTransportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

// One transport at a time: two enabled at once made `activeTunnelKind` answer nil and the connect go direct.
@MainActor
struct ConnectionEditorEngineTransportTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func draft(_ type: DatabaseType = .mysql) -> ConnectionDraft {
        ConnectionDraft.new(type: type, traits: traits(type))
    }

    private func edits(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> ConnectionFormEdits {
        ConnectionEditorEngine.edits(draft, traits, originalTraits: nil, EditorContext())
    }

    // The modes the record would carry, in the order the connect path reads them.
    private func enabledKinds(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> [ConnectionTunnelKind] {
        let edits = edits(draft, traits)
        var kinds: [ConnectionTunnelKind] = []
        if edits.sshTunnelMode != .disabled { kinds.append(.ssh) }
        if edits.cloudflareTunnelMode != .disabled { kinds.append(.cloudflare) }
        if edits.cloudSQLProxyMode != .disabled { kinds.append(.cloudSQLProxy) }
        if edits.socksProxyMode != .disabled { kinds.append(.socksProxy) }
        if edits.tunnelCommandMode != .disabled { kinds.append(.tunnelCommand) }
        return kinds
    }

    private func duckdb(mode: String) -> ConnectionDraft {
        var draft = draft(.duckdb)
        draft.setFieldValue(mode, for: "duckdbMode")
        draft.setFieldValue("quack.internal", for: "duckdbHost")
        return draft
    }

    private func importing(_ url: String) throws -> (draft: ConnectionDraft, traits: ConnectionTypeTraits) {
        let parsed = try ConnectionURLParser.parse(url).get()
        let traits = traits(parsed.type)
        var draft = ConnectionDraft.new(type: parsed.type, traits: traits)
        draft.apply(parsed, traits: traits, policy: .newConnection)
        return (ConnectionEditorEngine.normalized(draft, traits), traits)
    }

    // MARK: - Selection

    @Test("A new connection is direct")
    func defaultsToDirect() {
        let mysql = traits(.mysql)
        let draft = draft()
        #expect(draft.transport == nil)
        #expect(enabledKinds(draft, mysql).isEmpty)
    }

    @Test("Selecting a transport enables exactly that one")
    func selectionIsExclusive() {
        let mysql = traits(.mysql)
        for kind in ConnectionTunnelKind.formToggleable {
            var draft = draft()
            draft.selectTransport(kind)
            #expect(enabledKinds(draft, mysql) == [kind], "\(kind) did not enable alone")
            #expect(draft.transport == kind, "\(kind) did not round-trip")
        }
    }

    @Test("Switching transport disables the previous one")
    func switchingDisablesPrevious() {
        let mysql = traits(.mysql)
        for first in ConnectionTunnelKind.formToggleable {
            for second in ConnectionTunnelKind.formToggleable where second != first {
                var draft = draft()
                draft.selectTransport(first)
                draft.selectTransport(second)
                #expect(enabledKinds(draft, mysql) == [second], "\(first) survived a switch to \(second)")
            }
        }
    }

    @Test("Selecting direct disables every transport")
    func directDisablesEverything() {
        let mysql = traits(.mysql)
        var draft = draft()
        draft.selectTransport(.socksProxy)
        draft.selectTransport(nil)
        #expect(draft.transport == nil)
        #expect(enabledKinds(draft, mysql).isEmpty)
    }

    @Test("Switching away keeps the transport's configuration for switching back")
    func switchingPreservesConfiguration() {
        var draft = draft()
        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion.example.com"
        draft.ssh.username = "deploy"

        draft.selectTransport(.socksProxy)
        #expect(draft.ssh.host == "bastion.example.com")

        draft.selectTransport(.ssh)
        #expect(draft.ssh.host == "bastion.example.com")
        #expect(draft.ssh.username == "deploy")
    }

    @Test("A connection stored with two transports loads with one")
    func loadCollapsesLegacyMultiTransport() {
        let mysql = traits(.mysql)
        var stored = DatabaseConnection(name: "Legacy", host: "db.internal", port: 3_306, type: .mysql)
        stored.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))
        stored.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com"))
        stored.tunnelCommandMode = .inline(TunnelCommandConfiguration(method: .custom, command: "forward {port}"))

        let draft = ConnectionDraft.loaded(from: stored, secrets: .none, traits: mysql)

        #expect(draft.transport == .ssh)
        #expect(enabledKinds(draft, mysql) == [.ssh])
    }

    @Test("A transport the type no longer offers falls back to direct")
    func normalizeDropsUnavailableTransport() {
        let sqlite = traits(.sqlite)
        var draft = draft()
        draft.selectTransport(.cloudflare)

        let normalized = ConnectionEditorEngine.normalized(draft, sqlite)

        #expect(normalized.transport == nil)
        #expect(enabledKinds(normalized, sqlite).isEmpty)
    }

    // MARK: - What each type offers

    @Test("Direct is always offered first, exactly once, and nothing is offered twice")
    func availableTransportsAreWellFormed() {
        for type in DatabaseType.allKnownTypes {
            let available = ConnectionEditorEngine.availableTransports(draft(type), traits(type))
            #expect(available.first == .some(nil), "\(type.rawValue) does not offer direct first")
            #expect(Set(available).count == available.count, "\(type.rawValue) offers a duplicate transport")
        }
    }

    @Test("A file-based type offers the remote file transport rather than a port forward")
    func fileBasedTypeUsesRemoteFile() {
        let sqlite = traits(.sqlite)
        var draft = draft(.sqlite)
        let available = ConnectionEditorEngine.availableTransports(draft, sqlite)
        #expect(available.contains(.remoteFile))
        #expect(!available.contains(.ssh))

        draft.selectTransport(.remoteFile)
        #expect(draft.usesSSHServer)
        #expect(draft.transport == .remoteFile)
        #expect(edits(draft, sqlite).sshTunnelMode != .disabled)
    }

    @Test("The SSH server is offered as one transport, never as both of its flavours")
    func sshAndRemoteFileAreNeverOfferedTogether() {
        for type in DatabaseType.allKnownTypes {
            let available = ConnectionEditorEngine.availableTransports(draft(type), traits(type))
            #expect(
                !(available.contains(.ssh) && available.contains(.remoteFile)),
                "\(type.rawValue) offers both SSH flavours, so the picker cannot round-trip"
            )
        }
    }

    @Test("Weaviate offers the SSH tunnel and every other transport that forwards a port")
    func weaviateOffersPortForwards() {
        let available = ConnectionEditorEngine.availableTransports(draft(.weaviate), traits(.weaviate))
        #expect(available == [nil, .ssh, .cloudflare, .socksProxy, .tunnelCommand])
    }

    // A registry type's built-in entry once offered Cloudflare Tunnel with nothing to forward to.
    @Test("A type with no port forward and no remote file connects directly only")
    func typeWithoutPortForwardIsDirectOnly() {
        let manager = PluginManager.shared
        for type in DatabaseType.allKnownTypes
        where !manager.supportsSSH(for: type) && !manager.supportsRemoteDatabaseFile(for: type) {
            #expect(
                ConnectionEditorEngine.availableTransports(draft(type), traits(type)) == [nil],
                "\(type.rawValue) offers a transport it has no port to forward through"
            )
        }
    }

    @Test("A type that dials its host offers a port forward wherever it supports SSH")
    func networkTypesKeepTheirTransports() {
        let manager = PluginManager.shared
        for type in DatabaseType.allKnownTypes
        where manager.connectionMode(for: type) == .network && !manager.supportsRemoteDatabaseFile(for: type) {
            let available = ConnectionEditorEngine.availableTransports(draft(type), traits(type))
            #expect(available.contains(.ssh) == manager.supportsSSH(for: type), "\(type.rawValue)")
            #expect(available.contains(.socksProxy) == manager.supportsSOCKSProxy(for: type), "\(type.rawValue)")
        }
    }

    @Test("A selected transport always has a facet that shows it")
    func aSelectedTransportIsAlwaysReachable() {
        for type in DatabaseType.allKnownTypes {
            let traits = traits(type)
            let base = draft(type)
            for kind in ConnectionEditorEngine.availableTransports(base, traits).compactMap({ $0 }) {
                var draft = base
                draft.selectTransport(kind)
                #expect(
                    ConnectionEditorEngine.layout(draft, traits, EditorContext()).facet(.sshAndProxies) != nil,
                    "\(type.rawValue) hides SSH & Proxies while \(kind.rawValue) is on, so its issues have nowhere to show"
                )
            }
        }
    }

    // MARK: - DuckDB

    @Test("DuckDB in Local File offers no transport and no SSH & Proxies or SSL/TLS facet")
    func duckdbLocalHasNoTransportFacet() {
        let duckdbTraits = traits(.duckdb)
        let draft = duckdb(mode: "local")
        let layout = ConnectionEditorEngine.layout(draft, duckdbTraits, EditorContext())

        #expect(ConnectionEditorEngine.availableTransports(draft, duckdbTraits) == [nil])
        #expect(!duckdbTraits.supportsSSL)
        #expect(layout.facet(.sshAndProxies) == nil)
        #expect(layout.facet(.sslTLS) == nil)
    }

    @Test("DuckDB in Remote offers the SSH tunnel and every other transport that forwards a port, and no SSL/TLS facet")
    func duckdbRemoteOffersPortForwards() {
        let duckdbTraits = traits(.duckdb)
        let draft = duckdb(mode: "remote")
        let layout = ConnectionEditorEngine.layout(draft, duckdbTraits, EditorContext())

        #expect(ConnectionEditorEngine.availableTransports(draft, duckdbTraits) == [nil, .ssh, .cloudflare, .socksProxy, .tunnelCommand])
        #expect(layout.facet(.sshAndProxies) != nil)
        #expect(!ConnectionEditorEngine.showsSSL(draft, duckdbTraits))
        #expect(layout.facet(.sslTLS) == nil)
    }

    @Test("Switching DuckDB to Local File drops the transport it had in Remote and keeps the server")
    func duckdbLocalDropsTheRemoteTransport() {
        let duckdbTraits = traits(.duckdb)
        var draft = duckdb(mode: "remote")
        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion.example.com"

        draft.setFieldValue("local", for: "duckdbMode")
        let normalized = ConnectionEditorEngine.normalized(draft, duckdbTraits)

        #expect(normalized.transport == nil)
        #expect(enabledKinds(normalized, duckdbTraits).isEmpty)
        #expect(normalized.ssh.host == "bastion.example.com", "The server itself is kept for switching back")
    }

    @Test("A DuckDB Remote tunnel forwards to the server General names")
    func duckdbTunnelForwardsToTheServer() {
        let duckdbTraits = traits(.duckdb)
        var draft = duckdb(mode: "remote")
        draft.setFieldValue("9500", for: "duckdbPort")

        let endpoint = edits(draft, duckdbTraits).applied(to: DatabaseConnection(name: "")).tunnelForwardEndpoint

        #expect(endpoint.host == "quack.internal")
        #expect(endpoint.port == 9_500)
    }

    // MARK: - URL import

    @Test("A quack+ssh URL opens DuckDB in Remote on the SSH tunnel, with the SSL Mode it names")
    func quackSSHURLOpensRemoteOverSSH() throws {
        let imported = try importing("quack+ssh://deploy@bastion.example.com/quack.internal:9500/remotedb?sslmode=require")

        #expect(imported.draft.type == .duckdb)
        #expect(imported.draft.transport == .ssh, "Normalizing must not drop a tunnel the Remote fields can use")
        #expect(imported.draft.ssh.host == "bastion.example.com")
        let fields = imported.draft.fieldValues
        #expect(fields["duckdbMode"] == "remote")
        #expect(fields["duckdbHost"] == "quack.internal")
        #expect(fields["duckdbPort"] == "9500")
        #expect(fields["duckdbSSLMode"] == "required")
    }

    @Test("A URL naming an SSH server opens the editor on exactly that transport")
    func urlImportSelectsOneTransport() throws {
        let imported = try importing("mysql+ssh://deploy@bastion.example.com:22/dbuser@db.internal:3306/app")

        #expect(imported.draft.transport == .ssh)
        #expect(enabledKinds(imported.draft, imported.traits) == [.ssh])
        #expect(imported.draft.ssh.host == "bastion.example.com")
    }

    // MARK: - Values a transport owns

    @Test("Leaving the SSH server clears the remote file path it was carrying")
    func leavingSSHClearsRemoteFilePath() {
        var draft = draft(.sqlite)
        draft.selectTransport(.remoteFile)
        draft.ssh.remoteFilePath = "/var/db/app.sqlite"

        draft.selectTransport(nil)

        #expect(draft.ssh.remoteFilePath.isEmpty)
    }

    @Test("Changing the type clears a remote file path the new type cannot open")
    func retypeClearsRemoteFilePath() {
        var draft = draft(.sqlite)
        draft.selectTransport(.remoteFile)
        draft.ssh.remoteFilePath = "/var/db/app.sqlite"

        draft.retype(to: traits(.mysql), from: traits(.sqlite))

        #expect(draft.transport == nil)
        #expect(draft.ssh.remoteFilePath.isEmpty)
    }

    @Test("Leaving the port forward clears the socket path only it can reach")
    func leavingSSHClearsForwardSocketPath() {
        var draft = draft()
        draft.selectTransport(.ssh)
        draft.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        draft.selectTransport(.socksProxy)

        #expect(draft.sshForwardUnixSocketPath.isEmpty)
        #expect(!ConnectionEditorEngine.forwardsToUnixSocket(draft))
    }

    // A SQL Server connection changed to MySQL would otherwise leave its Kerberos password stored under the same id.
    @Test("A retyped connection still owns the previous type's secure fields")
    func retypeKeepsOwnershipOfTheOldTypesSecrets() throws {
        let manager = PluginManager.shared
        let secretive = DatabaseType.allKnownTypes.first { type in
            manager.additionalConnectionFields(for: type).contains { $0.isSecure }
        }
        let original = try #require(secretive, "No known type declares a secure connection field")
        let originalIds = Set(manager.additionalConnectionFields(for: original).filter(\.isSecure).map(\.id))

        let ownedIds = ConnectionEditorEngine.secureFieldsOwnedByForm(traits(.mysql), originalTraits: traits(original)).map(\.id)

        #expect(originalIds.isSubset(of: Set(ownedIds)))
        #expect(Set(ownedIds).count == ownedIds.count, "A field shared by both types is listed once")
    }

    @Test("A driver with no SSL/TLS facet cannot be blocked by an SSL rule")
    func sslIssuesAreSilentWhereThereIsNoSSLFacet() {
        let sqlite = traits(.sqlite)
        var fileDraft = draft(.sqlite)
        fileDraft.selectSSLMode(.verifyCa)
        fileDraft.ssl.caCertPath = ""
        #expect(!sqlite.supportsSSL)
        #expect(!ConnectionEditorEngine.issues(fileDraft, sqlite, EditorContext()).contains { $0.facet == .sslTLS })

        let mysql = traits(.mysql)
        var networked = draft()
        networked.selectSSLMode(.verifyCa)
        networked.ssl.caCertPath = ""
        #expect(mysql.supportsSSL)
        #expect(
            ConnectionEditorEngine.issues(networked, mysql, EditorContext()).contains { $0.row == .builtIn(.sslCACertificate) },
            "A driver that shows the field still requires it"
        )
    }

    // MARK: - Socket endpoint

    @Test("Choosing Socket clears the transport, leaves only Direct and keeps SSL/TLS")
    func socketClearsTheTransport() {
        let mysql = traits(.mysql)
        var draft = draft()
        draft.selectTransport(.ssh)
        draft.ssh.host = "bastion.example.com"

        draft.selectEndpoint(.localSocket)

        #expect(draft.transport == nil)
        #expect(enabledKinds(draft, mysql).isEmpty)
        #expect(ConnectionEditorEngine.availableTransports(draft, mysql) == [nil])
        #expect(ConnectionEditorEngine.layout(draft, mysql, EditorContext()).facet(.sslTLS) != nil, "SSL Mode still applies over a socket")
        #expect(draft.ssh.host == "bastion.example.com", "The server itself is kept")
    }

    @Test("Going back to Host and Port offers the transports again")
    func hostAndPortRestoresTransports() {
        let mysql = traits(.mysql)
        var draft = draft()
        let offered = ConnectionEditorEngine.availableTransports(draft, mysql)

        draft.selectEndpoint(.localSocket)
        draft.selectEndpoint(.hostAndPort)

        #expect(ConnectionEditorEngine.availableTransports(draft, mysql) == offered)
        #expect(offered.contains(.ssh))
    }

    @Test("A stored socket under an SSH tunnel loads as Host and Port and keeps the tunnel")
    func storedSocketUnderSSHKeepsTheTunnel() {
        let mysql = traits(.mysql)
        var stored = DatabaseConnection(name: "Mixed", host: "db.internal", port: 3_306, type: .mysql)
        stored.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        stored.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))

        let draft = ConnectionDraft.loaded(from: stored, secrets: .none, traits: mysql)

        #expect(draft.endpoint == .hostAndPort)
        #expect(draft.transport == .ssh)
        #expect(edits(draft, mysql).additionalFields[MySQLLocalSocket.fieldKey] == nil)
    }

    @Test("A socket connection saves its path and no transport")
    func socketEditsCarryThePath() {
        let mysql = traits(.mysql)
        var draft = draft()
        draft.name = "Local"
        draft.selectEndpoint(.localSocket)
        draft.localSocketPath = "/tmp/mysql.sock"

        let edits = edits(draft, mysql)

        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
        #expect(edits.ownedAdditionalFieldIDs.contains(MySQLLocalSocket.fieldKey))
        #expect(edits.applied(to: DatabaseConnection(name: "")).localSocketPath == "/tmp/mysql.sock")
        #expect(enabledKinds(draft, mysql).isEmpty)
        #expect(!ConnectionEditorEngine.issues(draft, mysql, EditorContext()).contains { $0.blocksSave })
    }

    @Test("An empty socket blocks Save from General")
    func emptySocketIsClaimedByGeneral() throws {
        let mysql = traits(.mysql)
        var draft = draft()
        draft.name = "Local"
        draft.selectEndpoint(.localSocket)

        let blocking = ConnectionEditorEngine.issues(draft, mysql, EditorContext()).filter(\.blocksSave)
        let first = try #require(blocking.first)
        #expect(first.facet == .general)
        #expect(first.row == .builtIn(.localSocketPath))
    }
}
