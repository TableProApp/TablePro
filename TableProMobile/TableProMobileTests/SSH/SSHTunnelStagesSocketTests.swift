//
//  SSHTunnelStagesSocketTests.swift
//  TableProMobileTests
//
//  Ownership of the real descriptors, against a loopback listener that accepts and then says
//  nothing. Measured before the hand-over guarantee landed: five failed handshakes left ten
//  descriptors open, five of them established TCP sockets to the SSH server.
//
//  Two observations, because one does not imply the other. The server side sees a zero-length
//  read, which is what proves the connection was broken; `shutdown` alone produces it, so the
//  socket's own local port is what proves the number was given back. Deleting `Darwin.close` from
//  `discard()` leaves every EOF assertion here passing and fails the port lookup.
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

    @Test("A discarded connect gives the descriptor back, not only the connection")
    func discardReleasesTheDescriptor() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }

        var connectedPorts: Set<Int> = []
        for _ in 0 ..< 5 {
            connectedPorts.insert(try await Self.connectThenDiscard(listener))
        }

        #expect(OpenSockets.awaitRelease(of: connectedPorts).isEmpty)
    }

    @Test("Cancelling inside the handshake returns at once and closes the socket")
    func cancellingHandshakeClosesTheSocket() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }

        let port = listener.port
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

        let banner = try #require(LoopbackListener.readLine(accepted, timeout: 5))
        #expect(banner.hasPrefix("SSH-2.0-"))

        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(cancelledAt)

        if case .success = result {
            Issue.record("expected the cancelled handshake to throw")
        }
        #expect(elapsed < 5)
        #expect(LoopbackListener.readsEOF(accepted, timeout: 5))
    }

    /// The local port the discarded connect was using, which the server side reads off the
    /// connection it accepted. It names that one socket for the rest of the test: no other suite
    /// can hold a socket on it while this one does.
    private static func connectThenDiscard(_ listener: LoopbackListener) async throws -> Int {
        let stages = LibSSH2TunnelStages()
        try await stages.connect(host: "127.0.0.1", port: listener.port)

        let accepted = try #require(listener.acceptOne(timeout: 2))
        defer { Darwin.close(accepted) }

        let connectedPort = try #require(LoopbackListener.peerPort(accepted))

        stages.discard()
        #expect(LoopbackListener.readsEOF(accepted, timeout: 2))
        return connectedPort
    }
}

/// Which of the named local ports this process still holds a socket for. It answers for the
/// sockets the test itself opened rather than for the whole descriptor table, so a suite running
/// beside this one cannot move it.
///
/// `getsockname` is what can tell a `shutdown` from a `close`, measured: it keeps answering with
/// the port after `shutdown(SHUT_RDWR)` and after the peer has closed, and fails with `EBADF` the
/// moment the descriptor goes. The server's zero-length read can tell neither.
private enum OpenSockets {
    static func holdingPorts(among ports: Set<Int>) -> Set<Int> {
        var held: Set<Int> = []
        for descriptor in 0 ..< getdtablesize() where fcntl(descriptor, F_GETFD) >= 0 {
            guard let port = localPort(of: descriptor), ports.contains(port) else { continue }
            held.insert(port)
        }
        return held
    }

    /// The ports still held at the deadline. `discard()` closes on the session queue, so the
    /// release lands after the call has returned; a leaked socket keeps its port forever.
    static func awaitRelease(of ports: Set<Int>, timeout: TimeInterval = 5) -> Set<Int> {
        let deadline = Date().addingTimeInterval(timeout)
        var held = holdingPorts(among: ports)
        while !held.isEmpty, Date() < deadline {
            usleep(100_000)
            held = holdingPorts(among: ports)
        }
        return held
    }

    private static func localPort(of descriptor: Int32) -> Int? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }

        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int($0.pointee.sin_port.bigEndian) }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int($0.pointee.sin6_port.bigEndian) }
            }
        default:
            return nil
        }
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

    /// The port the peer of an accepted connection is connected from, asked of the server side
    /// because the client side belongs to the code under test.
    static func peerPort(_ fd: Int32) -> Int? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(address.sin_port.bigEndian)
    }

    /// Whether the peer closed or shut down its end. `shutdown` and `close` both surface here as a
    /// zero-length read, so this proves the connection was broken and nothing about the descriptor.
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

    /// The first line the peer sends, which for libssh2 is its SSH version banner. Reading it is
    /// what names the step in flight: `libssh2_session_handshake` writes the banner and then blocks
    /// on the server's own, which this listener never sends, so a connect that has merely finished
    /// produces nothing here.
    static func readLine(_ fd: Int32, timeout: Int32) -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var bytes: [UInt8] = []
        while Date() < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) > 0 else { continue }

            var byte: UInt8 = 0
            guard recv(fd, &byte, 1, 0) == 1 else { return nil }
            guard byte != UInt8(ascii: "\n") else {
                return String(bytes: bytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            bytes.append(byte)
        }
        return nil
    }
}
