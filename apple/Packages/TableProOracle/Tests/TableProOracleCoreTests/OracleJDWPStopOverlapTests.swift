import Foundation
@testable import TableProOracleCore
import Testing

struct OracleJDWPStopOverlapTests {
    private let calcBody = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)

    private func makeSession(_ peer: RespondingPeer) async throws -> OracleJDWPDebugSession {
        let connection = OracleJDWPConnection(transport: peer, replyTimeout: .seconds(5))
        try await connection.handshake()
        let offline = OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
        return OracleJDWPDebugSession(
            connection: connection,
            target: offline,
            helper: offline,
            entryPoint: OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: calcBody, subprogram: "RUN", subprogramID: 3),
                overload: nil,
                parameters: [],
                result: nil
            ),
            invocation: OracleDebugStatements.Invocation(block: "BEGIN NULL; END;", binds: []),
            connectCall: Task { .success([]) },
            notices: []
        )
    }

    // Stop closes the socket, which fails the reply the breakpoint call still awaits: the call ends with Stop at once,
    // not at the 5 s reply timeout.
    @Test func testStopEndsABreakpointCallStillWaitingForItsReply() async throws {
        let (arrivals, arrival) = AsyncStream.makeStream(of: Void.self)
        let peer = RespondingPeer { _ in
            arrival.yield()
            return nil
        }
        let session = try await makeSession(peer)
        let breakpoint = Task { try await session.setBreakpoint(in: calcBody, line: 4) }
        var waiting = arrivals.makeAsyncIterator()
        _ = await waiting.next()
        let started = ContinuousClock.now
        #expect(await session.stop() == .ended)
        await #expect(throws: OracleDebugError.ended) { _ = try await breakpoint.value }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func testConcurrentStopsShareOneOutcomeAndLaterCallsSendNothing() async throws {
        let peer = RespondingPeer { _ in ([], 0, Data()) }
        let session = try await makeSession(peer)
        async let first = session.stop()
        async let second = session.stop()
        #expect(await [first, second] == [.ended, .ended])
        await #expect(throws: OracleDebugError.ended) { _ = try await session.setBreakpoint(in: calcBody, line: 4) }
        await #expect(throws: OracleDebugError.ended) { _ = try await session.source(of: calcBody) }
        #expect(peer.sent.isEmpty)
    }
}
