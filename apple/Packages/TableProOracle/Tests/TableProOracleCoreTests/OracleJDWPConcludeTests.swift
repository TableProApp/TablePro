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
}
