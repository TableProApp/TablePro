import Foundation
import os
@testable import TableProOracleCore
import Testing

struct OracleDBMSDebugSessionTests {
    private struct RefusedDelete: Error {}

    private typealias Statements = OracleDBMSDebugStatements

    private static let runCalc = OracleDebugUnit(owner: "PROBE", name: "RUN_CALC", kind: .procedure)
    private static let invocationBlock = "BEGIN PROBE.RUN_CALC; END;"
    private static let identity = OracleDebugSessionIdentity(sid: 42, serial: 7)
    private static let anonymousFrame: [String?] = [nil, nil, "0", nil, "1", nil]
    private static let runCalcFrame: [String?] = ["PROBE", "RUN_CALC", "1", "7", "3", nil]
    // Lines 3, 5 and 7 have code.
    private static let lineMap = payload(["0", "7", "A8"])

    private static func payload(_ fields: [String?]) -> [String?] {
        [OracleDebugPayload.encode(fields)]
    }

    private static func event(terminated: Bool = false, line: Int? = nil, breakpoint: Int? = nil, frames: [[String?]] = []) -> [String?] {
        let head: [String?] = [
            "0",
            String(terminated ? Statements.Reason.knlExit : Statements.Reason.breakpoint),
            terminated ? "1" : "0",
            line.map(String.init),
            breakpoint.map(String.init),
            String(frames.count)
        ]
        return payload(head + frames.flatMap { $0 })
    }

    private static func isContinue(_ sql: String, flags: Int) -> Bool {
        sql.contains("CONTINUE(l_info, \(flags),")
    }

    // The routine's call waits until `ended` opens, as a target paused at the supervisor does.
    private func makeSession(
        ended: Latch,
        callEndWait: Duration = OracleDebugSupport.callEndWait,
        supervisor respond: @escaping @Sendable (String) async throws -> [String?]
    ) -> (OracleDBMSDebugSession, target: ScriptedChannel, supervisor: ScriptedChannel) {
        let target = ScriptedChannel(rows: [[.string("42"), .string("7")]]) { sql in
            guard sql == Self.invocationBlock else { return [] }
            await ended.wait()
            throw OracleDebugError.server(code: 6_543, message: "ORA-06543")
        }
        let supervisor = ScriptedChannel { sql in
            if Self.isContinue(sql, flags: Statements.BreakFlags.abortExecution) {
                ended.open()
                return Self.event(terminated: true)
            }
            return try await respond(sql)
        }
        let session = OracleDBMSDebugSession(
            target: target,
            supervisor: supervisor,
            entryPoint: OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: Self.runCalc, subprogram: "RUN_CALC", subprogramID: 1),
                overload: nil,
                parameters: [],
                result: nil
            ),
            invocation: OracleDebugStatements.Invocation(block: Self.invocationBlock, binds: []),
            callEndWait: callEndWait,
            notices: []
        )
        return (session, target, supervisor)
    }

    // The target paused at the supervisor, then an answer the first stop read did not parse. The target is still
    // paused, so Stop aborts it there, which needs no ALTER SYSTEM, and the run ends confirmed.
    @Test func testStopAbortsATargetAFailedFirstStopLeftPaused() async throws {
        let ended = Latch()
        defer { ended.open() }
        let (session, _, supervisor) = makeSession(ended: ended) { sql in
            if sql.contains("SYNCHRONIZE") { return Self.event(line: 1, frames: [Self.anonymousFrame]) }
            if sql.contains("GET_LINE_MAP") { return ["not a payload"] }
            return []
        }
        try await session.start(breakpoints: [])
        await #expect(throws: OracleDebugError.unreadableAnswer) { _ = try await session.firstStop() }

        #expect(await session.stop() == .ended)
        let sent = supervisor.sent
        #expect(sent.contains { Self.isContinue($0, flags: Statements.BreakFlags.abortExecution) })
        #expect(!sent.contains { $0.contains("ALTER SYSTEM KILL") })
    }

    // The supervisor saw the routine end, but its call has not returned. A ROLLBACK would queue behind that call on
    // the target with no bound, so the run ends unconfirmed instead.
    @Test func testARunWhoseCallStillRunsEndsUnconfirmedWithoutQueueingARollback() async throws {
        let ended = Latch()
        defer { ended.open() }
        let (session, target, _) = makeSession(ended: ended, callEndWait: .milliseconds(200)) { sql in
            sql.contains("SYNCHRONIZE") ? Self.event(terminated: true) : []
        }
        try await session.start(breakpoints: [])

        let stop = await finished(within: 5) { try await session.firstStop() }
        #expect(stop == .failed(.stillRunning(Self.identity)))
        #expect(!target.sent.contains("ROLLBACK"))
    }

    // A delete the server refuses leaves the breakpoint set, so removing it again deletes it again.
    @Test func testARefusedDeleteCanBeRetried() async throws {
        let ended = Latch()
        defer { ended.open() }
        let refusals = OSAllocatedUnfairLock(initialState: 1)
        let (session, _, supervisor) = makeSession(ended: ended) { sql in
            if sql.contains("GET_LINE_MAP") { return Self.lineMap }
            if sql.contains("SYNCHRONIZE") { return Self.event(line: 1, frames: [Self.anonymousFrame]) }
            if sql.contains("SET_BREAKPOINT(l_program, 3,") { return Self.payload(["0", "1"]) }
            if sql.contains("SET_BREAKPOINT(l_program, 5,") { return Self.payload(["0", "2"]) }
            if Self.isContinue(sql, flags: Statements.BreakFlags.breakpointsOnly) {
                return Self.event(line: 3, breakpoint: 1, frames: [Self.anonymousFrame, Self.runCalcFrame])
            }
            if sql.contains("DELETE_BREAKPOINT(2)"), refusals.withLock({ left in defer { left -= 1 }; return left > 0 }) {
                throw RefusedDelete()
            }
            return []
        }
        try await session.start(breakpoints: [(unit: Self.runCalc, line: 5)])
        #expect(try await session.firstStop() == .paused(OracleDebugLocation(unit: Self.runCalc, line: 3)))

        await #expect(throws: (any Error).self) { try await session.removeBreakpoint(in: Self.runCalc, line: 5) }
        try await session.removeBreakpoint(in: Self.runCalc, line: 5)
        #expect(supervisor.sent.filter { $0.contains("DELETE_BREAKPOINT(2)") }.count == 2)
        #expect(await session.stop() == .ended)
    }

    // A breakpoint sent at start on line 4 lands on line 5; the host never learns that and removes it by line 4.
    @Test func testAStartBreakpointIsRemovedByTheLineItWasAskedFor() async throws {
        let ended = Latch()
        defer { ended.open() }
        let (session, _, supervisor) = makeSession(ended: ended) { sql in
            if sql.contains("GET_LINE_MAP") { return Self.lineMap }
            if sql.contains("SYNCHRONIZE") { return Self.event(line: 1, frames: [Self.anonymousFrame]) }
            if sql.contains("SET_BREAKPOINT(l_program, 3,") { return Self.payload(["0", "1"]) }
            if sql.contains("SET_BREAKPOINT(l_program, 5,") { return Self.payload(["0", "2"]) }
            if Self.isContinue(sql, flags: Statements.BreakFlags.breakpointsOnly) {
                return Self.event(line: 3, breakpoint: 1, frames: [Self.anonymousFrame, Self.runCalcFrame])
            }
            return []
        }
        try await session.start(breakpoints: [(unit: Self.runCalc, line: 4)])
        #expect(try await session.firstStop() == .paused(OracleDebugLocation(unit: Self.runCalc, line: 3)))

        try await session.removeBreakpoint(in: Self.runCalc, line: 4)
        #expect(supervisor.sent.contains { $0.contains("DELETE_BREAKPOINT(2)") })
        #expect(await session.stop() == .ended)
    }
}
