//
//  NetworkPaneLocalSocketTests.swift
//  TableProTests
//

import Darwin
import Foundation
@testable import TablePro
import Testing

@MainActor
struct NetworkPaneLocalSocketTests {
    private func socketConnection(path: String = "/tmp/mysql.sock", type: DatabaseType = .mysql) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Local", host: "localhost", port: 3_306, type: type)
        connection.additionalFields[MySQLLocalSocket.fieldKey] = path
        return connection
    }

    private func socketViewModel(path: String) -> NetworkPaneViewModel {
        let viewModel = NetworkPaneViewModel()
        viewModel.name = "Local"
        viewModel.type = .mysql
        viewModel.endpoint = .localSocket
        viewModel.localSocketPath = path
        return viewModel
    }

    @Test("Loading a socket connection selects Socket and fills the path")
    func loadsSocketConnection() {
        let viewModel = NetworkPaneViewModel()
        viewModel.load(from: socketConnection())

        #expect(viewModel.endpoint == .localSocket)
        #expect(viewModel.localSocketPath == "/tmp/mysql.sock")
        #expect(viewModel.usesLocalSocket)
    }

    @Test("Loading a TCP connection stays on Host and Port")
    func loadsTCPConnection() {
        let viewModel = NetworkPaneViewModel()
        viewModel.load(from: DatabaseConnection(name: "TCP", host: "db.internal", port: 3_306, type: .mysql))

        #expect(viewModel.endpoint == .hostAndPort)
        #expect(viewModel.localSocketPath.isEmpty)
        #expect(!viewModel.usesLocalSocket)
    }

    @Test("A stored socket under an SSH tunnel loads as Host and Port, since the tunnel is what connects")
    func socketUnderTunnelLoadsAsHostAndPort() {
        var connection = socketConnection()
        connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))

        let viewModel = NetworkPaneViewModel()
        viewModel.load(from: connection)

        #expect(viewModel.endpoint == .hostAndPort)
        #expect(viewModel.localSocketPath.isEmpty)
    }

    @Test("Writing in Socket mode stores the trimmed path with ~ expanded")
    func writesTrimmedExpandedPath() {
        var fields: [String: String] = [:]
        socketViewModel(path: "  /tmp/mysql.sock\n").write(into: &fields)
        #expect(fields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")

        var homeFields: [String: String] = [:]
        socketViewModel(path: "~/run/mysqld.sock").write(into: &homeFields)
        #expect(homeFields[MySQLLocalSocket.fieldKey] == NSHomeDirectory() + "/run/mysqld.sock")
    }

    @Test("Host and Port mode writes no socket, even with a path typed earlier")
    func hostAndPortWritesNoSocket() {
        let viewModel = socketViewModel(path: "/tmp/mysql.sock")
        viewModel.endpoint = .hostAndPort

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(fields[MySQLLocalSocket.fieldKey] == nil)
        #expect(viewModel.localSocketIssues.isEmpty)
    }

    @Test("An empty socket path blocks Save and names the field")
    func emptyPathIsRequired() {
        let viewModel = socketViewModel(path: "   ")
        let required = String(format: String(localized: "%@ is required"), String(localized: "Socket"))
        #expect(viewModel.validationIssues == [required])
    }

    @Test("A relative socket path blocks Save")
    func relativePathIsRejected() {
        let viewModel = socketViewModel(path: "mysql.sock")
        #expect(viewModel.validationIssues == [MySQLLocalSocket.PathIssue.notAbsolute.message])
    }

    @Test("A path past macOS's 103-byte limit blocks Save with its length")
    func longPathIsRejected() {
        let path = "/" + String(repeating: "a", count: 103)
        let viewModel = socketViewModel(path: path)
        #expect(viewModel.validationIssues == [MySQLLocalSocket.PathIssue.tooLong(bytes: 104).message])

        let atLimit = socketViewModel(path: "/" + String(repeating: "a", count: 102))
        #expect(atLimit.validationIssues.isEmpty)
    }

    @Test("A path under ~ is checked after expanding it, so it is absolute")
    func tildePathIsAbsolute() {
        #expect(socketViewModel(path: "~/mysql.sock").validationIssues.isEmpty)
    }

    @Test("Changing the type to PostgreSQL drops the socket")
    func typeChangeDropsSocket() {
        let viewModel = socketViewModel(path: "")
        viewModel.type = .postgresql

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(!viewModel.supportsLocalSocket)
        #expect(!viewModel.usesLocalSocket)
        #expect(fields[MySQLLocalSocket.fieldKey] == nil)
        #expect(viewModel.localSocketIssues.isEmpty)
    }

    @Test("Socket is offered for MySQL and MariaDB only")
    func socketIsOfferedPerType() {
        let cases: [(type: DatabaseType, offered: Bool)] = [
            (.mysql, true), (.mariadb, true), (.tidb, false), (.oceanbase, false),
            (.databend, false), (.postgresql, false), (.sqlite, false)
        ]
        for entry in cases {
            let viewModel = NetworkPaneViewModel()
            viewModel.type = entry.type
            #expect(viewModel.supportsLocalSocket == entry.offered, "\(entry.type.rawValue)")
        }
    }

    @Test("The prompt is the socket path a Homebrew or installer MySQL uses")
    func promptIsTheDefaultSocket() {
        let viewModel = NetworkPaneViewModel()
        viewModel.type = .mariadb
        #expect(viewModel.localSocketPrompt == "/tmp/mysql.sock")
    }

    @Test("A missing path, a plain file and a socket each read as such")
    func fileStatusFollowsTheFile() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("tp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.sock").path
        #expect(NetworkPaneViewModel.localSocketFileStatus(atPath: missing) == .missing)

        let file = directory.appendingPathComponent("plain.sock").path
        #expect(FileManager.default.createFile(atPath: file, contents: Data()))
        #expect(NetworkPaneViewModel.localSocketFileStatus(atPath: file) == .notSocket)

        let socketPath = directory.appendingPathComponent("m.sock").path
        let descriptor = try bindUnixSocket(at: socketPath)
        defer { close(descriptor) }
        #expect(NetworkPaneViewModel.localSocketFileStatus(atPath: socketPath) == .socket)

        let link = directory.appendingPathComponent("link.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: socketPath)
        #expect(NetworkPaneViewModel.localSocketFileStatus(atPath: link) == .socket)
    }

    @Test("The file status stays quiet until the path itself is valid")
    func fileStatusWaitsForAValidPath() {
        #expect(socketViewModel(path: "").localSocketFileStatus == nil)
        #expect(socketViewModel(path: "relative.sock").localSocketFileStatus == nil)
        #expect(socketViewModel(path: "/nonexistent-tablepro/m.sock").localSocketFileStatus == .missing)
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
