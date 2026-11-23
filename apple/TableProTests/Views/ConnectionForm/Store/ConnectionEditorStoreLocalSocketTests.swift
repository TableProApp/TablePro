//
//  ConnectionEditorStoreLocalSocketTests.swift
//  TableProTests
//

import Darwin
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreLocalSocketTests {
    private func socketStore(
        _ fixture: ConnectionEditorStoreFixture,
        type: DatabaseType,
        path: String,
        port: String? = nil
    ) -> ConnectionEditorStore {
        let store = fixture.makeStore(.new(type: type, parsedURL: nil))
        store.update { $0.name = "Local" }
        if let port {
            store.setPort(port)
        }
        store.selectEndpoint(.localSocket)
        store.update { $0.localSocketPath = path }
        return store
    }

    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("tp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A missing path, a plain file and a socket each read as such")
    func fileStatusFollowsTheFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SocketFileStatus.of(path: directory.appendingPathComponent("missing.sock").path) == .missing)

        let file = directory.appendingPathComponent("plain.sock").path
        #expect(FileManager.default.createFile(atPath: file, contents: Data()))
        #expect(SocketFileStatus.of(path: file) == .notSocket)

        let socketPath = directory.appendingPathComponent("m.sock").path
        let descriptor = try bindUnixSocket(at: socketPath)
        defer { close(descriptor) }
        #expect(SocketFileStatus.of(path: socketPath) == .socket)

        let link = directory.appendingPathComponent("link.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: socketPath)
        #expect(SocketFileStatus.of(path: link) == .socket)
    }

    @Test("The file status stays quiet until the path itself is valid")
    func fileStatusWaitsForAValidPath() throws {
        let fixture = try ConnectionEditorStoreFixture()
        #expect(socketStore(fixture, type: .mysql, path: "").localSocketFileStatus == nil)
        #expect(socketStore(fixture, type: .mysql, path: "relative.sock").localSocketFileStatus == nil)
        #expect(socketStore(fixture, type: .mysql, path: "/nonexistent-tablepro/m.sock").localSocketFileStatus == .missing)
    }

    @Test("The file status checks the socket file the folder and port name")
    func fileStatusChecksTheSocketFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ConnectionEditorStoreFixture()

        let store = socketStore(fixture, type: .postgresql, path: directory.path, port: "5433")
        #expect(store.localSocketFileStatus == .missing)

        let descriptor = try bindUnixSocket(at: directory.appendingPathComponent(".s.PGSQL.5433").path)
        defer { close(descriptor) }
        #expect(store.localSocketFileStatus == .socket)

        store.setPort("5434")
        #expect(store.localSocketFileStatus == .missing)
    }

    @Test("~/.pgpass is matched by localhost for /tmp and by the folder otherwise")
    func pgpassEndpoint() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let pgpass = ConnectionEditorEngine.pgpassFieldId
        #expect(ConnectionTypeTraits.live(for: .postgresql, pluginManager: .shared).field(pgpass) != nil)

        let defaultFolder = socketStore(fixture, type: .postgresql, path: "/tmp", port: "5433")
        defaultFolder.setFieldValue("true", for: pgpass)
        #expect(defaultFolder.pgpassLookup?.host == "localhost")
        #expect(defaultFolder.pgpassLookup?.port == 5_433)

        let otherFolder = socketStore(fixture, type: .postgresql, path: "/var/run/postgresql")
        otherFolder.setFieldValue("true", for: pgpass)
        #expect(otherFolder.pgpassLookup?.host == "/var/run/postgresql")
        #expect(otherFolder.pgpassLookup?.port == 5_432)

        let tcp = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        tcp.setFieldValue("true", for: pgpass)
        tcp.update { $0.host = "db.example.com" }
        tcp.setPort("6432")
        #expect(tcp.pgpassLookup?.host == "db.example.com")
        #expect(tcp.pgpassLookup?.port == 6_432)
        tcp.update { $0.host = "" }
        #expect(tcp.pgpassLookup?.host == "localhost")
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
