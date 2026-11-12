import Foundation
import TableProSSHConfig
import TableProSSHTransport
import Testing

@testable import TablePro

private final class LoopbackSocket {
    let descriptor: Int32
    let port: Int

    init?(listening: Bool) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, !listening || listen(fd, 4) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    var hasPendingConnection: Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&pollDescriptor, 1, 0) > 0
    }

    deinit {
        Darwin.close(descriptor)
    }
}

struct SSHTunnelLocalPortTests {
    private func freeLoopbackPort() throws -> Int {
        try #require(LoopbackSocket(listening: false)).port
    }

    @Test("A taken local port is skipped for the next free one")
    func takenPortIsSkipped() throws {
        let taken = try #require(LoopbackSocket(listening: true))
        let freePort = try freeLoopbackPort()

        let listener = try LibSSH2TunnelFactory.bindLocalListener(candidates: [taken.port, freePort])
        defer { Darwin.close(listener.descriptor) }

        #expect(listener.port == freePort)
        withExtendedLifetime(taken) {}
    }

    @Test("Every candidate port taken reports that no local port is available")
    func everyPortTakenReportsNoPort() throws {
        let taken = try #require(LoopbackSocket(listening: true))

        #expect(throws: SSHTunnelError.noAvailablePort) {
            try LibSSH2TunnelFactory.bindLocalListener(candidates: [taken.port])
        }
        withExtendedLifetime(taken) {}
    }

    @Test("A tunnel with no free local port fails before it dials or signs in to the SSH server")
    func noLocalPortFailsBeforeDialing() async throws {
        let taken = try #require(LoopbackSocket(listening: true))
        let sshServer = try #require(LoopbackSocket(listening: true))
        let takenPort = taken.port
        let sshPort = sshServer.port
        let manager = SSHTunnelManager(localPortCandidates: { [takenPort] })

        await #expect(throws: SSHTunnelError.noAvailablePort) {
            try await manager.createTunnel(
                connectionId: UUID(),
                sshHost: "127.0.0.1",
                sshPort: sshPort,
                sshUsername: "tester",
                authMethod: .password,
                sshPassword: "secret",
                destination: .tcp(host: "127.0.0.1", port: 5_432),
                deadline: ConnectionDeadline(configuredSeconds: 2)
            )
        }

        #expect(!sshServer.hasPendingConnection)
        withExtendedLifetime(taken) {}
    }
}
