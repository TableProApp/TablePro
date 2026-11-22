//
//  ConnectionEditorEngineTransportIssueTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineTransportIssueTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func draft(_ type: DatabaseType, transport: ConnectionTunnelKind?) -> ConnectionDraft {
        var draft = ConnectionDraft.new(type: type, traits: traits(type))
        draft.name = "Remote"
        draft.selectTransport(transport)
        return draft
    }

    private func transportIssues(_ draft: ConnectionDraft) -> [FieldIssue] {
        ConnectionEditorEngine.issues(draft, traits(draft.type), EditorContext()).filter { $0.facet == .sshAndProxies }
    }

    private func messages(_ draft: ConnectionDraft, on row: BuiltInRow) -> [String] {
        transportIssues(draft).filter { $0.row == .builtIn(row) }.map(\.message)
    }

    // MARK: - Remote File

    // A check that answered whenever SSH was on once disabled Save on every tunnelled MySQL and PostgreSQL connection.
    @Test("An SSH-tunnelled network connection is never asked for a remote file path")
    func networkConnectionWithTunnelStaysValid() {
        for type in [DatabaseType.mysql, .postgresql] {
            var draft = draft(type, transport: .ssh)
            draft.ssh.host = "bastion.example.com"
            draft.ssh.username = "deploy"

            #expect(transportIssues(draft).isEmpty, "\(type.rawValue)")
        }
    }

    @Test("A file-backed connection on Remote File with no path is told what is missing")
    func fileBackedConnectionRequiresAPath() {
        var draft = draft(.sqlite, transport: .remoteFile)
        draft.ssh.host = "prod-1"
        draft.ssh.username = "deploy"
        draft.ssh.remoteFilePath = ""

        let issues = transportIssues(draft)
        #expect(issues.count == 1)
        #expect(issues.first?.row == .builtIn(.remoteFilePath))
    }

    @Test("A file-backed connection naming both a server and a path has nothing to report")
    func completeRemoteFileIsValid() {
        var draft = draft(.sqlite, transport: .remoteFile)
        draft.ssh.host = "prod-1"
        draft.ssh.username = "deploy"
        draft.ssh.remoteFilePath = "/srv/app.db"

        #expect(transportIssues(draft).isEmpty)
    }

    @Test("Direct leaves no remote file to validate")
    func directReportsNothing() {
        #expect(transportIssues(draft(.sqlite, transport: nil)).isEmpty)
    }

    // MARK: - SOCKS proxy

    @Test("Direct reports no SOCKS issues")
    func socksDirectNoIssues() {
        var draft = draft(.postgresql, transport: nil)
        draft.socksProxy.host = ""
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("A SOCKS proxy requires a host, in SSH & Proxies")
    func socksRequiresHost() {
        var draft = draft(.postgresql, transport: .socksProxy)
        draft.socksProxy.host = "   "
        #expect(messages(draft, on: .socksHost).contains { $0.localizedCaseInsensitiveContains("host") })

        draft.socksProxy.host = "proxy.example.com"
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("A SOCKS proxy port must be in range")
    func socksPortRange() {
        var draft = draft(.postgresql, transport: .socksProxy)
        draft.socksProxy.host = "proxy.example.com"

        draft.socksProxy.port = "70000"
        #expect(messages(draft, on: .socksPort).contains { $0.localizedCaseInsensitiveContains("port") })

        draft.socksProxy.port = "not-a-port"
        #expect(messages(draft, on: .socksPort).contains { $0.localizedCaseInsensitiveContains("port") })

        draft.socksProxy.port = "1080"
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("SOCKS credentials are optional")
    func socksCredentialsOptional() {
        var draft = draft(.postgresql, transport: .socksProxy)
        draft.socksProxy.host = "proxy.example.com"
        draft.socksProxy.username = ""
        draft.socksProxy.password = ""
        #expect(transportIssues(draft).isEmpty)
    }

    // MARK: - Cloud SQL Auth Proxy

    @Test("Direct reports no Cloud SQL issues")
    func cloudSQLDirectNoIssues() {
        var draft = draft(.postgresql, transport: nil)
        draft.cloudSQLProxy.instanceConnectionName = "bad"
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("Cloud SQL requires a well-formed instance connection name")
    func cloudSQLRequiresInstanceName() {
        var draft = draft(.postgresql, transport: .cloudSQLProxy)
        draft.cloudSQLProxy.instanceConnectionName = "bad"
        #expect(!messages(draft, on: .cloudSQLInstance).isEmpty)

        draft.cloudSQLProxy.instanceConnectionName = "p:r:i"
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("A manual Cloud SQL port must be in range")
    func cloudSQLManualPortRange() {
        var draft = draft(.postgresql, transport: .cloudSQLProxy)
        draft.cloudSQLProxy.instanceConnectionName = "p:r:i"
        draft.cloudSQLProxy.automaticPort = false

        draft.cloudSQLProxy.localPort = "70000"
        #expect(!messages(draft, on: .cloudSQLLocalPort).isEmpty)

        draft.cloudSQLProxy.localPort = "5432"
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("Service account key mode requires a key")
    func cloudSQLServiceAccountKeyRequired() {
        var draft = draft(.postgresql, transport: .cloudSQLProxy)
        draft.cloudSQLProxy.instanceConnectionName = "p:r:i"
        draft.cloudSQLProxy.authMode = .serviceAccountKey

        draft.cloudSQLProxy.serviceAccountKeyJSON = ""
        #expect(!messages(draft, on: .cloudSQLServiceAccountKey).isEmpty)

        draft.cloudSQLProxy.serviceAccountKeyJSON = "{\"type\":\"service_account\"}"
        #expect(transportIssues(draft).isEmpty)
    }

    // MARK: - Cloudflare Tunnel

    @Test("Direct reports no Cloudflare issues")
    func cloudflareDirectNoIssues() {
        var draft = draft(.postgresql, transport: nil)
        draft.cloudflare.accessHostname = ""
        #expect(transportIssues(draft).isEmpty)
    }

    @Test("A Cloudflare tunnel requires a hostname")
    func cloudflareRequiresHostname() {
        var draft = draft(.postgresql, transport: .cloudflare)
        draft.cloudflare.accessHostname = "   "
        #expect(messages(draft, on: .cloudflareHostname).contains { $0.localizedCaseInsensitiveContains("hostname") })
    }

    @Test("A manual Cloudflare port must be within range")
    func cloudflarePortRange() {
        var draft = draft(.postgresql, transport: .cloudflare)
        draft.cloudflare.accessHostname = "db.example.com"
        draft.cloudflare.automaticPort = false
        draft.cloudflare.localPort = "70000"
        #expect(messages(draft, on: .cloudflareLocalPort).contains { $0.localizedCaseInsensitiveContains("port") })
    }

    @Test("Service token mode requires an id and a secret")
    func cloudflareServiceTokenRequired() {
        var draft = draft(.postgresql, transport: .cloudflare)
        draft.cloudflare.accessHostname = "db.example.com"
        draft.cloudflare.authMethod = .serviceToken
        #expect(!transportIssues(draft).isEmpty)
    }

    @Test("A valid browser sign-in configuration has no issues")
    func cloudflareValidBrowserConfig() {
        var draft = draft(.postgresql, transport: .cloudflare)
        draft.cloudflare.accessHostname = "db.example.com"
        draft.cloudflare.authMethod = .browserSSO
        #expect(transportIssues(draft).isEmpty)
    }

    // MARK: - SSH forward to a socket

    @Test("An absolute socket file path gets no advice")
    func acceptsAbsoluteSocketPath() {
        #expect(SSHForwardSocketAdvice.of(path: "/var/run/postgresql/.s.PGSQL.5432") == nil)
    }

    @Test("An empty path gets no advice, because the field is optional")
    func emptyPathIsFine() {
        #expect(SSHForwardSocketAdvice.of(path: "") == nil)
        #expect(SSHForwardSocketAdvice.of(path: "   ") == nil)
    }

    @Test("A relative path is flagged")
    func flagsRelativePath() {
        #expect(SSHForwardSocketAdvice.of(path: "var/run/postgresql") == .notAbsolute)
    }

    @Test("A trailing slash is flagged, because ssh forwards to the socket file, not its directory")
    func flagsDirectoryPath() {
        #expect(SSHForwardSocketAdvice.of(path: "/var/run/postgresql/") == .looksLikeDirectory)
    }

    @Test("Loading a tunnelled connection fills the socket path and forwards to it")
    func loadsSocketPath() {
        var connection = DatabaseConnection(name: "socket", host: "db.internal", port: 5_432, type: .postgresql)
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"
        connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))

        let draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: traits(.postgresql))

        #expect(draft.sshForwardUnixSocketPath == "/var/run/postgresql/.s.PGSQL.5432")
        #expect(ConnectionEditorEngine.forwardsToUnixSocket(draft))
    }

    @Test("Writing trims the socket path")
    func writeTrimsSocketPath() {
        let postgres = traits(.postgresql)
        var draft = draft(.postgresql, transport: .ssh)
        draft.sshForwardUnixSocketPath = "  /var/run/postgresql/.s.PGSQL.5432  "

        let fields = ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext()).additionalFields

        #expect(fields[DatabaseConnection.sshForwardUnixSocketPathKey] == "/var/run/postgresql/.s.PGSQL.5432")
    }

    @Test("Writing an empty socket path stores nothing")
    func writeOmitsEmptySocketPath() {
        let postgres = traits(.postgresql)
        var draft = draft(.postgresql, transport: .ssh)
        draft.sshForwardUnixSocketPath = "   "

        let fields = ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext()).additionalFields

        #expect(fields[DatabaseConnection.sshForwardUnixSocketPathKey] == nil)
        #expect(!ConnectionEditorEngine.forwardsToUnixSocket(draft))
    }

    // The field's prompt is the type's own path, and a generic one when the type has none.
    @Test("The socket path prompt follows the database type")
    func socketPromptFollowsType() {
        #expect(traits(.mysql).defaultUnixSocketPath == "/var/run/mysqld/mysqld.sock")
        #expect(traits(.postgresql).defaultUnixSocketPath == "/var/run/postgresql/.s.PGSQL.5432")
        #expect(traits(.clickhouse).defaultUnixSocketPath == nil)
    }
}
