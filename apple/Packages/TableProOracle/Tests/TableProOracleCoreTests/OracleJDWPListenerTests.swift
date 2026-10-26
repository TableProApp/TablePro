import Foundation
import Network
@testable import TableProOracleCore
import Testing

// The listener runs on loopback here: the same code a database server reaches over the network.
struct OracleJDWPListenerTests {
    private let ports: ClosedRange<UInt16> = 47_100...47_199

    private func dial(_ port: UInt16, sending payload: Data?) -> NWConnection {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state, let payload {
                connection.send(content: payload, completion: .idempotent)
            }
        }
        connection.start(queue: .global())
        return connection
    }

    @Test func testAPeerFromTheDatabasesAddressIsAccepted() async throws {
        let listener = try await OracleJDWPListener.open(ports: ports, bindAddresses: ["127.0.0.1"], allowedPeers: ["127.0.0.1"])
        let peer = dial(listener.port, sending: OracleJDWPPacket.handshake)
        defer { peer.cancel() }
        let connection = try await listener.accept(timeout: .seconds(5))
        await connection.close()
    }

    // A strict address check refuses a peer the database host does not resolve to, and names it for the person.
    @Test func testAPeerFromAnotherAddressIsClosedAndNamed() async throws {
        let listener = try await OracleJDWPListener.open(ports: ports, bindAddresses: ["127.0.0.1"], allowedPeers: ["10.9.8.7"])
        let peer = dial(listener.port, sending: OracleJDWPPacket.handshake)
        defer { peer.cancel() }
        await #expect(throws: OracleJDWPListenerError.timedOut(rejected: ["127.0.0.1"])) {
            try await listener.accept(timeout: .seconds(1))
        }
    }

    // A connection that never sends the handshake is dropped after two seconds, and the real one still gets in.
    @Test func testASilentPeerDoesNotHoldTheListener() async throws {
        let listener = try await OracleJDWPListener.open(ports: ports, bindAddresses: ["127.0.0.1"], allowedPeers: ["127.0.0.1"])
        let silent = dial(listener.port, sending: nil)
        defer { silent.cancel() }
        let real = dial(listener.port, sending: OracleJDWPPacket.handshake)
        defer { real.cancel() }
        let started = ContinuousClock.now
        let connection = try await listener.accept(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(2))
        await connection.close()
    }

    @Test func testCancellingTheWaitEndsIt() async throws {
        let listener = try await OracleJDWPListener.open(ports: ports, bindAddresses: ["127.0.0.1"], allowedPeers: ["127.0.0.1"])
        let started = ContinuousClock.now
        let waiting = Task { try await listener.accept(timeout: .seconds(30)) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // `localhost` resolves to ::1 first on macOS, but Docker Desktop delivers a container's connection on 127.0.0.1.
    @Test func testALoopbackRouteBinds127() async {
        #expect(await OracleDebugNetwork.bindAddresses(debuggerHost: "localhost", databaseHost: "localhost", databasePort: 1_521)
            == ["127.0.0.1"])
        #expect(await OracleDebugNetwork.bindAddresses(debuggerHost: "name.invalid", databaseHost: "localhost", databasePort: 1_521)
            == ["127.0.0.1"])
        #expect(await OracleDebugNetwork.bindAddresses(debuggerHost: "::1", databaseHost: "localhost", databasePort: 1_521)
            == ["::1"])
        #expect(OracleDebugNetwork.isLoopback("::1"))
        #expect(OracleDebugNetwork.isLoopback("127.0.0.1"))
        #expect(!OracleDebugNetwork.isLoopback("192.168.1.20"))
    }

    @Test func testAddressesCompareInOneSpelling() {
        #expect(OracleDebugNetwork.normalized("::FFFF:127.0.0.1") == "127.0.0.1")
        #expect(OracleDebugNetwork.normalized("fe80::1%en0") == "fe80::1")
        #expect(OracleDebugNetwork.normalized("[::1]") == "::1")
        #expect(OracleDebugNetwork.resolve("127.0.0.1") == ["127.0.0.1"])
        #expect(OracleDebugNetwork.localInterfaceAddresses().contains("127.0.0.1"))
    }
}
