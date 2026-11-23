//
//  ConnectionEditorEngineLocalSocketTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineLocalSocketTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func socketConnection(path: String = "/tmp/mysql.sock", type: DatabaseType = .mysql) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Local", host: "localhost", port: 3_306, type: type)
        connection.additionalFields[MySQLLocalSocket.fieldKey] = path
        return connection
    }

    private func loaded(_ connection: DatabaseConnection) -> ConnectionDraft {
        ConnectionDraft.loaded(from: connection, secrets: .none, traits: traits(connection.type))
    }

    private func socketDraft(_ type: DatabaseType = .mysql, path: String, port: String? = nil) -> ConnectionDraft {
        let traits = traits(type)
        var draft = ConnectionDraft.new(type: type, traits: traits)
        draft.name = "Local"
        if let port {
            draft.setPort(port, traits: traits)
        }
        draft.selectEndpoint(.localSocket)
        draft.localSocketPath = path
        return draft
    }

    private func edits(_ draft: ConnectionDraft) -> ConnectionFormEdits {
        ConnectionEditorEngine.edits(draft, traits(draft.type), originalTraits: nil, EditorContext())
    }

    private func socketIssues(_ draft: ConnectionDraft) -> [String] {
        ConnectionEditorEngine.issues(draft, traits(draft.type), EditorContext())
            .filter { $0.row == .builtIn(.localSocketPath) }
            .map(\.message)
    }

    // MARK: - MySQL

    @Test("Loading a socket connection selects Socket and fills the path")
    func loadsSocketConnection() {
        let draft = loaded(socketConnection())
        #expect(draft.endpoint == .localSocket)
        #expect(draft.localSocketPath == "/tmp/mysql.sock")
        #expect(ConnectionEditorEngine.usesLocalSocket(draft, traits(.mysql)))
    }

    @Test("Loading a TCP connection stays on Host and Port")
    func loadsTCPConnection() {
        let draft = loaded(DatabaseConnection(name: "TCP", host: "db.internal", port: 3_306, type: .mysql))
        #expect(draft.endpoint == .hostAndPort)
        #expect(draft.localSocketPath.isEmpty)
        #expect(!ConnectionEditorEngine.usesLocalSocket(draft, traits(.mysql)))
    }

    @Test("A stored socket under an SSH tunnel loads as Host and Port, since the tunnel is what connects")
    func socketUnderTunnelLoadsAsHostAndPort() {
        var connection = socketConnection()
        connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))
        let draft = loaded(connection)
        #expect(draft.endpoint == .hostAndPort)
        #expect(draft.localSocketPath.isEmpty)
    }

    @Test("Writing in Socket mode stores the trimmed path with ~ expanded")
    func writesTrimmedExpandedPath() {
        #expect(edits(socketDraft(path: "  /tmp/mysql.sock\n")).additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
        #expect(
            edits(socketDraft(path: "~/run/mysqld.sock")).additionalFields[MySQLLocalSocket.fieldKey]
                == NSHomeDirectory() + "/run/mysqld.sock"
        )
    }

    @Test("Host and Port mode writes no socket, even with a path typed earlier")
    func hostAndPortWritesNoSocket() {
        var draft = socketDraft(path: "/tmp/mysql.sock")
        draft.selectEndpoint(.hostAndPort)
        #expect(edits(draft).additionalFields[MySQLLocalSocket.fieldKey] == nil)
        #expect(socketIssues(draft).isEmpty)
    }

    @Test("An empty socket path blocks Save and names the field")
    func emptyPathIsRequired() {
        let required = String(format: String(localized: "%@ is required"), String(localized: "Socket"))
        #expect(socketIssues(socketDraft(path: "   ")) == [required])
    }

    @Test("A relative socket path blocks Save")
    func relativePathIsRejected() {
        #expect(socketIssues(socketDraft(path: "mysql.sock")) == [MySQLLocalSocket.PathIssue.notAbsolute.message])
    }

    @Test("A path past macOS's 103-byte limit blocks Save with its length")
    func longPathIsRejected() {
        let path = "/" + String(repeating: "a", count: 103)
        #expect(socketIssues(socketDraft(path: path)) == [MySQLLocalSocket.PathIssue.tooLong(bytes: 104).message])
        #expect(socketIssues(socketDraft(path: "/" + String(repeating: "a", count: 102))).isEmpty)
    }

    @Test("A path under ~ is checked after expanding it, so it is absolute")
    func tildePathIsAbsolute() {
        #expect(socketIssues(socketDraft(path: "~/mysql.sock")).isEmpty)
    }

    @Test("Changing the type to Redshift drops the socket")
    func typeChangeDropsSocket() {
        let redshift = traits(.redshift)
        var draft = socketDraft(path: "")
        draft.retype(to: redshift, from: traits(.mysql))
        #expect(!redshift.supportsLocalSocket)
        #expect(!ConnectionEditorEngine.usesLocalSocket(draft, redshift))
        #expect(edits(draft).additionalFields[MySQLLocalSocket.fieldKey] == nil)
        #expect(socketIssues(draft).isEmpty)
    }

    @Test("Socket is offered for MySQL, MariaDB and PostgreSQL only")
    func socketIsOfferedPerType() {
        let cases: [(type: DatabaseType, offered: Bool)] = [
            (.mysql, true), (.mariadb, true), (.tidb, false), (.oceanbase, false),
            (.databend, false), (.postgresql, true), (.redshift, false), (.cockroachdb, false),
            (DatabaseType(rawValue: "PGlite"), false), (.sqlite, false)
        ]
        for entry in cases {
            let traits = traits(entry.type)
            #expect(traits.supportsLocalSocket == entry.offered, "\(entry.type.rawValue)")
            let layout = ConnectionEditorEngine.layout(ConnectionDraft.new(type: entry.type, traits: traits), traits, EditorContext())
            #expect(layout.contains(.builtIn(.endpointKind)) == entry.offered, "\(entry.type.rawValue)")
        }
    }

    @Test("The prompt is the socket path a Homebrew or installer MySQL uses")
    func promptIsTheDefaultSocket() {
        #expect(traits(.mariadb).defaultLocalSocketPath == "/tmp/mysql.sock")
    }

    // MARK: - PostgreSQL

    // The Socket row offers these folders only when the path names a directory.
    @Test("PostgreSQL offers Socket, prompts /tmp and suggests the common folders")
    func postgresOffersSocket() {
        let postgres = traits(.postgresql)
        #expect(postgres.supportsLocalSocket)
        #expect(postgres.localSocketIsDirectory)
        #expect(postgres.defaultLocalSocketPath == "/tmp")
        #expect(PostgreSQLLocalSocket.commonDirectories == ["/tmp", "/var/run/postgresql"])
        #expect(!traits(.mysql).localSocketIsDirectory)
    }

    @Test("Socket leaves Direct only and drops SSL, and the connection rows report nothing")
    func postgresSocketDropsSSL() {
        let postgres = traits(.postgresql)
        var draft = socketDraft(.postgresql, path: "/tmp")
        draft.selectSSLMode(.required)
        draft.ssl.clientCertPath = "/tmp/client.crt"

        #expect(ConnectionEditorEngine.availableTransports(draft, postgres) == [nil])
        #expect(postgres.supportsSSL)
        #expect(!ConnectionEditorEngine.showsSSL(draft, postgres))
        let layout = ConnectionEditorEngine.layout(draft, postgres, EditorContext())
        let connectionRows = layout.facet(.general)?.sections.first { $0.id == "connection" }?.rows ?? []
        var issues = ConnectionEditorEngine.issues(draft, postgres, EditorContext(), layout: layout)
        #expect(!issues.contains { $0.row == .builtIn(.sslClientKey) })
        #expect(!issues.contains { connectionRows.contains($0.row) })

        draft.selectEndpoint(.hostAndPort)
        #expect(ConnectionEditorEngine.showsSSL(draft, postgres))
        issues = ConnectionEditorEngine.issues(draft, postgres, EditorContext())
        #expect(issues.contains { $0.row == .builtIn(.sslClientKey) })
    }

    @Test("A MySQL socket keeps its SSL settings")
    func mysqlSocketKeepsSSL() {
        let mysql = traits(.mysql)
        let draft = socketDraft(path: "/tmp/mysql.sock")
        #expect(ConnectionEditorEngine.showsSSL(draft, mysql))
        #expect(ConnectionEditorEngine.layout(draft, mysql, EditorContext()).facet(.sslTLS) != nil)
    }

    @Test("A folder is saved with the port, and the port names the socket file")
    func savesDirectoryAndPort() {
        let edits = edits(socketDraft(.postgresql, path: "/var/run/postgresql/", port: "5434"))
        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/var/run/postgresql")
        #expect(edits.port == 5_434)

        let connection = edits.applied(to: DatabaseConnection(name: ""))
        #expect(connection.localSocketFile == "/var/run/postgresql/.s.PGSQL.5434")
        #expect(connection.transportSSLConfiguration.mode == .disabled)
    }

    @Test("A socket file is saved as its folder and the port in its name")
    func savesSocketFileAsDirectory() {
        let edits = edits(socketDraft(.postgresql, path: "/tmp/.s.PGSQL.5433", port: "5432"))
        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp")
        #expect(edits.port == 5_433)
    }

    @Test("A relative path, a comma and a socket file over 103 bytes block Save")
    func postgresPathIssues() {
        #expect(socketIssues(socketDraft(.postgresql, path: "")).count == 1)
        #expect(socketIssues(socketDraft(.postgresql, path: "run/postgresql")) == [PostgreSQLLocalSocket.PathIssue.notAbsolute.message])
        #expect(socketIssues(socketDraft(.postgresql, path: "/tmp,/var/run")) == [PostgreSQLLocalSocket.PathIssue.comma.message])

        let directory = "/" + String(repeating: "a", count: 88)
        #expect(socketIssues(socketDraft(.postgresql, path: directory, port: "5432")).isEmpty)
        #expect(
            socketIssues(socketDraft(.postgresql, path: directory, port: "54321"))
                == [PostgreSQLLocalSocket.PathIssue.tooLong(bytes: 104).message]
        )
    }

    @Test("The direct summary names the socket and says no SSL is used")
    func directSummary() {
        let summary = ConnectionTunnelKind.directSummary(isFileBased: false, usesLocalSocket: true, localSocketSkipsTLS: true)
        #expect(summary != ConnectionTunnelKind.directSummary(isFileBased: false, usesLocalSocket: true, localSocketSkipsTLS: false))
    }
}
