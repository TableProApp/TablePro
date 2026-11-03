import Darwin
import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import Testing

private struct SocketFolder {
    let folder: URL

    var handshake: URL {
        MCPHandshakeLocation.file(in: folder)
    }

    var socketPath: String {
        MCPSocketLocation.primarySocket(in: folder).path
    }

    func write(socketPath: String) throws {
        let payload = MCPHandshakePayload(
            socketPath: socketPath,
            token: "tp_test",
            pid: ProcessInfo.processInfo.processIdentifier,
            instanceId: "instance",
            protocolVersion: MCPProtocolVersion.latest.rawValue,
            expiresAt: Date().addingTimeInterval(3_600)
        )
        try writeRaw(try MCPHandshakeCoding.encoder().encode(payload))
    }

    func writeRaw(_ data: Data) throws {
        try? FileManager.default.removeItem(at: handshake)
        try #require(FileManager.default.createFile(
            atPath: handshake.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ))
    }

    func listen(at path: String? = nil) throws -> MCPUnixSocketListener {
        let listener = MCPUnixSocketListener(path: path ?? socketPath) { $0.cancel() }
        try listener.start()
        return listener
    }

    func chmod(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
    }
}

private func withFolder(_ body: (SocketFolder) throws -> Void) throws {
    let folder = SocketFolder(folder: try MCPTestSocketFolder.make())
    defer { try? FileManager.default.removeItem(at: folder.folder) }
    try body(folder)
}

private func failure(loading url: URL) -> MCPHandshakeTrustFailure? {
    do {
        _ = try MCPHandshakeTrust.load(at: url)
        return nil
    } catch {
        return error as? MCPHandshakeTrustFailure
    }
}

struct MCPHandshakeSocketTrustTests {
    @Test("A socket the user owns, in the 0700 folder that holds the handshake, is trusted")
    func trustsSocketInPrivateFolder() throws {
        try withFolder { folder in
            let listener = try folder.listen()
            defer { listener.stop() }
            try folder.write(socketPath: folder.socketPath)

            let loaded = try MCPHandshakeTrust.load(at: folder.handshake)
            #expect(loaded.socketPath == folder.socketPath)
            #expect(loaded.credentials() == MCPUpstreamCredentials(socketPath: folder.socketPath, bearerToken: "tp_test"))
        }
    }

    @Test("A socket folder another account can enter is refused", arguments: [0o750, 0o711, 0o705])
    func refusesFolderOthersCanEnter(mode: Int) throws {
        try withFolder { folder in
            let listener = try folder.listen()
            defer { listener.stop() }
            try folder.write(socketPath: folder.socketPath)
            try folder.chmod(mode)

            #expect(failure(loading: folder.handshake) == .socketFolderNotPrivate)
        }
    }

    @Test("A missing socket, or a file that is not a socket, is refused")
    func refusesWhatIsNotASocket() throws {
        try withFolder { folder in
            try folder.write(socketPath: folder.socketPath)
            #expect(failure(loading: folder.handshake) == .notASocket)

            try #require(FileManager.default.createFile(atPath: folder.socketPath, contents: Data("x".utf8)))
            #expect(failure(loading: folder.handshake) == .notASocket)
        }
    }

    @Test("A live socket outside the handshake's folder is refused, even in another private folder")
    func refusesSocketOutsideTheFolder() throws {
        try withFolder { folder in
            let elsewhere = try MCPTestSocketFolder.make()
            defer { try? FileManager.default.removeItem(at: elsewhere) }
            let foreignPath = MCPSocketLocation.primarySocket(in: elsewhere).path
            let listener = try folder.listen(at: foreignPath)
            defer { listener.stop() }

            try folder.write(socketPath: foreignPath)
            #expect(failure(loading: folder.handshake) == .socketOutsidePrivateFolder)

            let escaping = folder.folder.path + "/../" + elsewhere.lastPathComponent + "/" + MCPSocketLocation.fileName
            try folder.write(socketPath: escaping)
            #expect(failure(loading: folder.handshake) == .socketOutsidePrivateFolder)
        }
    }

    @Test("A socket path longer than sun_path is refused")
    func refusesOverlongPath() throws {
        try withFolder { folder in
            let long = folder.folder.path + "/" + String(repeating: "s", count: MCPSocketLocation.maxPathBytes) + ".sock"
            try folder.write(socketPath: long)
            #expect(failure(loading: folder.handshake) == .socketOutsidePrivateFolder)
        }
    }

    @Test("A version 2 handshake, which named a TCP port, is refused")
    func refusesTheTcpHandshake() throws {
        try withFolder { folder in
            let listener = try folder.listen()
            defer { listener.stop() }
            let pid = ProcessInfo.processInfo.processIdentifier
            try folder.writeRaw(Data(#"""
            {"version":2,"port":23508,"token":"tp_test","pid":\#(pid),"instanceId":"instance",\#
            "protocolVersion":"\#(MCPProtocolVersion.latest.rawValue)","expiresAt":"2999-01-01T00:00:00Z"}
            """#.utf8))

            #expect(failure(loading: folder.handshake) == .unsupportedVersion(2))
        }
    }

    @Test("A support folder too deep for sun_path binds in a private temporary folder the bridge trusts")
    @MainActor
    func longSupportFolderFallsBack() throws {
        try withFolder { root in
            let support = root.folder.appendingPathComponent(String(repeating: "d", count: 80), isDirectory: true)
            let file = MCPHandshakeFile(directory: support, temporaryDirectory: root.folder)

            let path = try file.prepareSocketPath()
            let fallbackFolder = MCPSocketLocation.fallbackFolder(temporaryDirectory: root.folder)
            #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == fallbackFolder.standardizedFileURL.path)
            #expect(MCPSocketLocation.fits(path))
            #expect(MCPSocketLocation.isPrivateFolder(fallbackFolder))

            let listener = try root.listen(at: path)
            defer { listener.stop() }
            let handshake = SocketFolder(folder: support)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try handshake.write(socketPath: path)
            let loaded = try MCPHandshakeTrust.load(at: handshake.handshake, temporaryDirectory: root.folder)
            #expect(loaded.socketPath == path)
        }
    }

    @Test("A support folder that fits binds next to the handshake")
    @MainActor
    func shortSupportFolderBindsInPlace() throws {
        try withFolder { root in
            let support = root.folder.appendingPathComponent("TablePro", isDirectory: true)
            let file = MCPHandshakeFile(directory: support, temporaryDirectory: root.folder)

            let path = try file.prepareSocketPath()
            #expect(path == MCPSocketLocation.primarySocket(in: support).path)
            #expect(MCPSocketLocation.isPrivateFolder(support))
        }
    }
}
