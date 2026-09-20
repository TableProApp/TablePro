//
//  SSHTunnelStagesSocketTests.swift
//  TableProMobileTests
//
//  Ownership of the real descriptors, against a loopback listener that accepts and then says
//  nothing. Measured before the hand-over guarantee landed: five failed handshakes left ten
//  descriptors open, five of them established TCP sockets to the SSH server. The server side is
//  what has to observe the close, because freeing the session happens on the session queue after
//  the blocking call returns, while the socket is broken at once.
//

import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

@Suite("SSH tunnel stages sockets", .serialized)
struct SSHTunnelStagesSocketTests {
    @Test("A discarded connect closes the socket it opened")
    func discardClosesTheSocket() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }

        let stages = LibSSH2TunnelStages()
        try await stages.connect(host: "127.0.0.1", port: listener.port)

        let accepted = try #require(listener.acceptOne(timeout: 2))
        defer { Darwin.close(accepted) }

        stages.discard()

        #expect(LoopbackListener.readsEOF(accepted, timeout: 2))
    }

    @Test("Repeated failed attempts leave no socket open")
    func repeatedAttemptsLeakNothing() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }

        var accepted: [Int32] = []
        defer { for fd in accepted { Darwin.close(fd) } }

        for _ in 0 ..< 5 {
            let stages = LibSSH2TunnelStages()
            try await stages.connect(host: "127.0.0.1", port: listener.port)
            accepted.append(try #require(listener.acceptOne(timeout: 2)))
            stages.discard()
        }

        #expect(accepted.count == 5)
        #expect(accepted.allSatisfy { LoopbackListener.readsEOF($0, timeout: 2) })
    }

    @Test("Cancelling during the handshake returns at once and closes the socket")
    func cancellingHandshakeClosesTheSocket() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }

        let port = listener.port
        let started = Date()
        let task = Task {
            try await SSHTunnelFactory.create(
                config: SSHConfiguration(
                    host: "127.0.0.1",
                    port: port,
                    username: "deploy",
                    authMethod: .password
                ),
                remoteHost: "db.internal",
                remotePort: 5_432,
                credentials: SSHTunnelCredentials(password: "secret"),
                prompter: StubPrompter(answer: true),
                hostKeyStore: HostKeyStore(
                    filePath: FileManager.default.temporaryDirectory
                        .appendingPathComponent("known_hosts-\(UUID().uuidString)").path
                )
            )
        }

        let accepted = try #require(listener.acceptOne(timeout: 5))
        defer { Darwin.close(accepted) }

        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(started)

        if case .success = result {
            Issue.record("expected the cancelled connect to throw")
        }
        #expect(elapsed < 5)
        #expect(LoopbackListener.readsEOF(accepted, timeout: 5))
    }
}

/// A loopback TCP listener that accepts and says nothing, which is what makes a libssh2 handshake
/// block for its whole timeout.
private final class LoopbackListener {
    struct SetupFailure: Error {}

    let port: Int
    private let fd: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SetupFailure() }

        var option: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &option, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socketFD, 16) == 0 else {
            Darwin.close(socketFD)
            throw SetupFailure()
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(socketFD)
            throw SetupFailure()
        }

        fd = socketFD
        port = Int(boundAddress.sin_port.bigEndian)
    }

    func close() {
        Darwin.close(fd)
    }

    func acceptOne(timeout: Int32) -> Int32? {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, timeout * 1_000) > 0 else { return nil }

        var clientAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(fd, $0, &length)
            }
        }
        return clientFD >= 0 ? clientFD : nil
    }

    /// Whether the peer closed or shut down its end. `shutdown` and `close` both surface here as a
    /// zero-length read, which is the only observation that proves the descriptor was released.
    static func readsEOF(_ fd: Int32, timeout: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) > 0 else { continue }

            var byte: UInt8 = 0
            if recv(fd, &byte, 1, 0) == 0 { return true }
            if pollFD.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        }
        return false
    }
}
