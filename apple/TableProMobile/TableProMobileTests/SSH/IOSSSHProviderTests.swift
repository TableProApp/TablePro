import Foundation
import os
import TableProDatabase
import TableProModels
import TableProSSHTransport
import Testing

@testable import TableProMobile

@Suite("iOS SSH provider", .timeLimit(.minutes(1)))
struct IOSSSHProviderTests {
    private let connectionId = UUID()
    private let config = SSHConfiguration(host: "bastion.example.com", username: "deploy")

    private func provider(opening tunnels: [FakeTunnel]) -> IOSSSHProvider {
        let queue = OSAllocatedUnfairLock(initialState: tunnels)
        return IOSSSHProvider(secureStore: MockSecureStore()) { _ in
            queue.withLock { $0.removeFirst() }
        }
    }

    private func deaths(of provider: IOSSSHProvider) -> AsyncStream<UUID> {
        AsyncStream { continuation in
            provider.observeTunnelDeaths { continuation.yield($0) }
        }
    }

    @Test("A tunnel that stops on its own is reported for its connection")
    func reportsDeath() async throws {
        let tunnel = FakeTunnel()
        let provider = provider(opening: [tunnel])
        var reported = deaths(of: provider).makeAsyncIterator()

        _ = try await provider.createTunnel(
            config: config, connectionId: connectionId, sshProfileId: nil,
            destination: .tcp(host: "db", port: 5_432), prompter: nil
        )
        tunnel.die()

        #expect(await reported.next() == connectionId)
    }

    @Test("A dead tunnel leaves the store, so closing the connection does not close it again")
    func deathEmptiesStore() async throws {
        let tunnel = FakeTunnel()
        let provider = provider(opening: [tunnel])
        var reported = deaths(of: provider).makeAsyncIterator()

        _ = try await provider.createTunnel(
            config: config, connectionId: connectionId, sshProfileId: nil,
            destination: .tcp(host: "db", port: 5_432), prompter: nil
        )
        tunnel.die()
        _ = await reported.next()
        try await provider.closeTunnel(for: connectionId)

        #expect(tunnel.closeCount == 0)
    }

    @Test("A tunnel that died before the provider listened is still reported")
    func reportsEarlyDeath() async throws {
        let tunnel = FakeTunnel()
        tunnel.die()
        let provider = provider(opening: [tunnel])
        var reported = deaths(of: provider).makeAsyncIterator()

        _ = try await provider.createTunnel(
            config: config, connectionId: connectionId, sshProfileId: nil,
            destination: .tcp(host: "db", port: 5_432), prompter: nil
        )

        #expect(await reported.next() == connectionId)
    }

    @Test("A tunnel closed by its owner is not reported, and the next one still is")
    func closedTunnelIsNotADeath() async throws {
        let closed = FakeTunnel()
        let next = FakeTunnel()
        let provider = provider(opening: [closed, next])
        var reported = deaths(of: provider).makeAsyncIterator()

        let first = try await provider.createTunnel(
            config: config, connectionId: connectionId, sshProfileId: nil,
            destination: .tcp(host: "db", port: 5_432), prompter: nil
        )
        try await provider.closeTunnel(id: first.id)
        closed.die()
        let otherConnection = UUID()
        _ = try await provider.createTunnel(
            config: config, connectionId: otherConnection, sshProfileId: nil,
            destination: .tcp(host: "db", port: 5_432), prompter: nil
        )
        next.die()

        #expect(closed.closeCount == 1)
        #expect(await reported.next() == otherConnection)
    }
}

nonisolated private final class FakeTunnel: ProvidedTunnel, @unchecked Sendable {
    let localPort = 61_000
    private let notice = SSHTunnelDeathNotice()
    private let closes = OSAllocatedUnfairLock(initialState: 0)

    var closeCount: Int { closes.withLock { $0 } }

    func close() {
        closes.withLock { $0 += 1 }
    }

    func onDeath(_ handler: @escaping @Sendable () -> Void) {
        notice.onDeath(handler)
    }

    func die() {
        notice.died()
    }
}
