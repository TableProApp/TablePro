import Foundation
@testable import TableProOracleCore
import Testing

struct OracleJDWPConcludeTests {
    // The routine sits in DBMS_SESSION.SLEEP, which never returns to PL/SQL to see the socket close. Its call holds
    // the target's gate, so a ROLLBACK there would wait for the sleep: the step ends unconfirmed instead.
    @Test func testASocketThatClosesDuringALongCallEndsTheRunUnconfirmed() async throws {
        let calcBody = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)
        let identity = OracleDebugSessionIdentity(sid: 42, serial: 7)
        let invocation = "BEGIN PROBE.PKG_CALC.RUN; END;"
        let sleeping = Latch()
        defer { sleeping.open() }
        let (calls, call) = AsyncStream.makeStream(of: Void.self)
        let target = ScriptedChannel { sql in
            guard sql == invocation else { return [] }
            call.yield()
            await sleeping.wait()
            return []
        }
        let peer = RespondingPeer { sent in
            if sent.commandSet == OracleJDWPCommand.virtualMachine, sent.command == OracleJDWPCommand.idSizes {
                return ([OracleJDWPRecording.vmStartEvent], 0, replyBody(OracleJDWPRecording.idSizesReply))
            }
            return ([], 0, Data())
        }
        let connection = OracleJDWPConnection(transport: peer, replyTimeout: .seconds(5))
        try await connection.handshake()
        let session = OracleJDWPDebugSession(
            connection: connection,
            target: target,
            helper: ScriptedChannel(),
            entryPoint: OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: calcBody, subprogram: "RUN", subprogramID: 3),
                overload: nil,
                parameters: [],
                result: nil
            ),
            invocation: OracleDebugStatements.Invocation(block: invocation, binds: []),
            connectCall: Task { .success([]) },
            targetIdentity: identity,
            callEndWait: .milliseconds(200),
            notices: []
        )
        try await session.start(breakpoints: [])

        let firstStop = Task { await finished(within: 5) { try await session.firstStop() } }
        var started = calls.makeAsyncIterator()
        _ = await started.next()
        peer.close()

        #expect(await firstStop.value == .failed(.stillRunning(identity)))
        #expect(!target.sent.contains("ROLLBACK"))
    }

    // Stop closes the socket, and the routine's call fails with it. ORA-30687 is the server ending the session; a
    // failed transport (the target's own connection dropped too) ends the call only on this side, so the target is
    // killed through the helper and the end stays unconfirmed.
    @Test(arguments: [
        (OracleCoreError.connectionClosed, false),
        (OracleCoreError.queryFailed("ORA-30687: session terminated by debugger"), true)
    ])
    func testStopConfirmsTheEndOnlyFromTheServersAnswer(endedWith: OracleCoreError, serverAnswered: Bool) async throws {
        let calcBody = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)
        let identity = OracleDebugSessionIdentity(sid: 42, serial: 7)
        let invocation = "BEGIN PROBE.PKG_CALC.RUN; END;"
        let socketClosed = Latch()
        defer { socketClosed.open() }
        let (calls, call) = AsyncStream.makeStream(of: Void.self)
        let target = ScriptedChannel { sql in
            guard sql == invocation else { return [] }
            call.yield()
            await socketClosed.wait()
            throw endedWith
        }
        let helper = ScriptedChannel()
        let peer = RespondingPeer { sent in
            if sent.commandSet == OracleJDWPCommand.virtualMachine, sent.command == OracleJDWPCommand.idSizes {
                return ([OracleJDWPRecording.vmStartEvent], 0, replyBody(OracleJDWPRecording.idSizesReply))
            }
            return ([], 0, Data())
        }
        let connection = OracleJDWPConnection(transport: ClosingPeer(peer: peer) { socketClosed.open() }, replyTimeout: .seconds(5))
        try await connection.handshake()
        let session = OracleJDWPDebugSession(
            connection: connection,
            target: target,
            helper: helper,
            entryPoint: OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: calcBody, subprogram: "RUN", subprogramID: 3),
                overload: nil,
                parameters: [],
                result: nil
            ),
            invocation: OracleDebugStatements.Invocation(block: invocation, binds: []),
            connectCall: Task { .success([]) },
            targetIdentity: identity,
            notices: []
        )
        try await session.start(breakpoints: [])

        let firstStop = Task { await finished(within: 5) { try await session.firstStop() } }
        var started = calls.makeAsyncIterator()
        _ = await started.next()

        #expect(await session.stop() == (serverAnswered ? .ended : .unconfirmed(identity)))
        #expect(helper.sent.contains(where: { $0.hasPrefix("ALTER SYSTEM KILL SESSION '42,7'") }) == !serverAnswered)
        #expect(await firstStop.value == (serverAnswered ? .failed(.stopped) : .failed(.stillRunning(identity))))
    }
}

// Tells the test when this side closes the socket, which is when the database sees the debugger go.
private final class ClosingPeer: OracleJDWPTransport {
    private let peer: RespondingPeer
    private let onClose: @Sendable () -> Void

    init(peer: RespondingPeer, onClose: @escaping @Sendable () -> Void) {
        self.peer = peer
        self.onClose = onClose
    }

    func send(_ data: Data) async throws {
        try await peer.send(data)
    }

    func receive() async throws -> Data? {
        try await peer.receive()
    }

    func close() {
        peer.close()
        onClose()
    }
}
