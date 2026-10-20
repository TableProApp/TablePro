//
//  NetworkPanePostgreSQLSocketTests.swift
//  TableProTests
//

import Darwin
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct NetworkPanePostgreSQLSocketTests {
    private func socketForm(path: String, port: String = "5432") -> ConnectionFormCoordinator {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.name = "Local"
        coordinator.network.type = .postgresql
        coordinator.network.port = port
        coordinator.selectEndpoint(.localSocket)
        coordinator.network.localSocketPath = path
        return coordinator
    }

    @Test("PostgreSQL offers Socket, prompts /tmp and suggests the common folders")
    func offersSocket() {
        let network = socketForm(path: "").network
        #expect(network.supportsLocalSocket)
        #expect(network.localSocketIsDirectory)
        #expect(network.localSocketPrompt == "/tmp")
        #expect(network.localSocketSuggestions == ["/tmp", "/var/run/postgresql"])

        let mysql = NetworkPaneViewModel()
        mysql.type = .mysql
        #expect(!mysql.localSocketIsDirectory)
        #expect(mysql.localSocketSuggestions.isEmpty)
    }

    @Test("Socket leaves Direct only and drops SSL, but keeps the Network tab")
    func socketDropsSSL() {
        let coordinator = socketForm(path: "/tmp")
        coordinator.ssl.select(.required)
        coordinator.ssl.clientCertPath = "/tmp/client.crt"

        #expect(coordinator.availableTransports == [nil])
        #expect(coordinator.supportsSSL)
        #expect(!coordinator.showsSSL)
        #expect(coordinator.ssl.validationIssues.isEmpty)
        #expect(coordinator.visibleTabs.contains(.network))
        #expect(ConnectionFormTab.network.validationIssues(for: coordinator).isEmpty)

        coordinator.selectEndpoint(.hostAndPort)
        #expect(coordinator.showsSSL)
        #expect(!coordinator.ssl.validationIssues.isEmpty)
    }

    @Test("A MySQL socket keeps its SSL settings")
    func mysqlSocketKeepsSSL() {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = .mysql
        coordinator.selectEndpoint(.localSocket)
        #expect(coordinator.showsSSL)
    }

    @Test("A folder is saved with the port, and the port names the socket file")
    func savesDirectoryAndPort() {
        let edits = socketForm(path: "/var/run/postgresql/", port: "5434").buildEdits()
        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/var/run/postgresql")
        #expect(edits.port == 5_434)

        let connection = edits.applied(to: DatabaseConnection(name: ""))
        #expect(connection.localSocketFile == "/var/run/postgresql/.s.PGSQL.5434")
        #expect(connection.transportSSLConfiguration.mode == .disabled)
    }

    @Test("A socket file is saved as its folder and the port in its name")
    func savesSocketFileAsDirectory() {
        let edits = socketForm(path: "/tmp/.s.PGSQL.5433", port: "5432").buildEdits()
        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp")
        #expect(edits.port == 5_433)
    }

    @Test("A relative path, a comma and a socket file over 103 bytes block Save")
    func pathIssues() {
        #expect(socketForm(path: "").network.localSocketIssues.count == 1)
        #expect(socketForm(path: "run/postgresql").network.localSocketIssues == [PostgreSQLLocalSocket.PathIssue.notAbsolute.message])
        #expect(socketForm(path: "/tmp,/var/run").network.localSocketIssues == [PostgreSQLLocalSocket.PathIssue.comma.message])

        let directory = "/" + String(repeating: "a", count: 88)
        #expect(socketForm(path: directory, port: "5432").network.localSocketIssues.isEmpty)
        #expect(
            socketForm(path: directory, port: "54321").network.localSocketIssues
                == [PostgreSQLLocalSocket.PathIssue.tooLong(bytes: 104).message]
        )
    }

    @Test("The file status checks the socket file the folder and port name")
    func fileStatusChecksTheSocketFile() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("tp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let form = socketForm(path: directory.path, port: "5433")
        #expect(form.network.localSocketFileStatus == .missing)

        let descriptor = try bindUnixSocket(at: directory.appendingPathComponent(".s.PGSQL.5433").path)
        defer { close(descriptor) }
        #expect(form.network.localSocketFileStatus == .socket)

        form.network.port = "5434"
        #expect(form.network.localSocketFileStatus == .missing)
    }

    @Test("~/.pgpass is matched by localhost for /tmp and by the folder otherwise")
    func pgpassEndpoint() {
        let defaultFolder = socketForm(path: "/tmp", port: "5433").network.pgpassEndpoint
        #expect(defaultFolder.host == "localhost")
        #expect(defaultFolder.port == 5_433)
        let otherFolder = socketForm(path: "/var/run/postgresql").network.pgpassEndpoint
        #expect(otherFolder.host == "/var/run/postgresql")
        #expect(otherFolder.port == 5_432)

        let tcp = NetworkPaneViewModel()
        tcp.type = .postgresql
        tcp.host = "db.example.com"
        tcp.port = "6432"
        #expect(tcp.pgpassEndpoint.host == "db.example.com")
        #expect(tcp.pgpassEndpoint.port == 6_432)
        tcp.host = ""
        #expect(tcp.pgpassEndpoint.host == "localhost")
    }

    @Test("The Network tab names the socket and says no SSL is used")
    func directSummary() {
        let summary = ConnectionTunnelKind.directSummary(isFileBased: false, usesLocalSocket: true, localSocketSkipsTLS: true)
        #expect(summary != ConnectionTunnelKind.directSummary(isFileBased: false, usesLocalSocket: true, localSocketSkipsTLS: false))
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() where index < buffer.count - 1 {
                buffer[index] = byte
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }
}
