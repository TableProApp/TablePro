import Foundation
import os
@testable import TableProOracleCore
import Testing

struct OracleJDWPBreakpointTests {
    private static let calcBody = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)

    // A VM whose PKG_CALC body has one method, RUN, with code on `lines`; the unit counts as loaded once `isLoaded`
    // says so. Records the request id it gave each breakpoint, by code index, which is the line.
    private final class VM: @unchecked Sendable {
        private struct State {
            var isLoaded: Bool
            var refusesNextClear = false
            var nextRequest: Int32 = 0
            var breakpoints: [Int64: Int32] = [:]
        }

        private let state: OSAllocatedUnfairLock<State>
        private let lines: [Int]

        init(lines: [Int], isLoaded: Bool) {
            self.lines = lines
            state = OSAllocatedUnfairLock(initialState: State(isLoaded: isLoaded))
        }

        func load() {
            state.withLock { $0.isLoaded = true }
        }

        func refuseNextClear() {
            state.withLock { $0.refusesNextClear = true }
        }

        func request(atLine line: Int) -> Int32? {
            state.withLock { $0.breakpoints[Int64(line)] }
        }

        func answer(_ sent: RespondingPeer.Sent) -> (events: [Data], errorCode: UInt16, body: Data)? {
            var writer = OracleJDWPWriter(sizes: .oracle)
            switch (sent.commandSet, sent.command) {
            case (OracleJDWPCommand.virtualMachine, OracleJDWPCommand.idSizes):
                return ([OracleJDWPRecording.vmStartEvent], 0, replyBody(OracleJDWPRecording.idSizesReply))
            case (OracleJDWPCommand.virtualMachine, OracleJDWPCommand.classesBySignature):
                guard state.withLock({ $0.isLoaded }) else {
                    writer.i32(0)
                    break
                }
                writer.i32(1)
                writer.u8(1)
                writer.id(2, .referenceType)
                writer.i32(7)
            case (OracleJDWPCommand.referenceType, OracleJDWPCommand.methods):
                writer.i32(1)
                writer.id(5, .method)
                writer.string("RUN")
                writer.string("()V")
                writer.i32(9)
            case (OracleJDWPCommand.method, OracleJDWPCommand.lineTable):
                writer.i64(Int64(lines.first ?? 0))
                writer.i64(Int64(lines.last ?? 0))
                writer.i32(Int32(lines.count))
                for line in lines {
                    writer.i64(Int64(line))
                    writer.i32(Int32(line))
                }
            case (OracleJDWPCommand.eventRequest, OracleJDWPCommand.clear):
                let refuses = state.withLock { current -> Bool in
                    defer { current.refusesNextClear = false }
                    return current.refusesNextClear
                }
                // INVALID_EVENT_TYPE, with the session still up.
                if refuses { return ([], 102, Data()) }
            case (OracleJDWPCommand.eventRequest, OracleJDWPCommand.set):
                let id = state.withLock { current -> Int32 in
                    current.nextRequest += 1
                    if sent.body.first == OracleJDWPEventKind.breakpoint.rawValue {
                        current.breakpoints[Self.codeIndex(of: sent.body)] = current.nextRequest
                    }
                    return current.nextRequest
                }
                writer.i32(id)
            default:
                break
            }
            return ([], 0, writer.data)
        }

        // A breakpoint request ends with its location, whose last eight bytes are the code index.
        private static func codeIndex(of body: Data) -> Int64 {
            body.suffix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        }
    }

    private func makeSession(_ vm: VM, helper: ScriptedChannel? = nil) async throws -> (OracleJDWPDebugSession, RespondingPeer) {
        let peer = RespondingPeer { vm.answer($0) }
        let connection = OracleJDWPConnection(transport: peer, replyTimeout: .seconds(5))
        try await connection.handshake()
        let offline = OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
        let session = OracleJDWPDebugSession(
            connection: connection,
            target: offline,
            helper: helper ?? offline,
            entryPoint: OracleDebugEntryPoint(
                entry: OracleDebugEntry(unit: Self.calcBody, subprogram: "RUN", subprogramID: 3),
                overload: nil,
                parameters: [],
                result: nil
            ),
            invocation: OracleDebugStatements.Invocation(block: "BEGIN NULL; END;", binds: []),
            connectCall: Task { .success([]) },
            notices: []
        )
        return (session, peer)
    }

    private func clears(_ peer: RespondingPeer) -> [Data] {
        peer.sent
            .filter { $0.commandSet == OracleJDWPCommand.eventRequest && $0.command == OracleJDWPCommand.clear }
            .map(\.body)
    }

    private func clear(_ request: Int32?) -> Data {
        OracleJDWPRequest.clear(kind: .breakpoint, requestID: request ?? -1, sizes: .oracle)
    }

    // Line 4 has no code, so the breakpoint sent at start lands on line 5; the host never learns that.
    @Test func testAStartBreakpointIsRemovedByTheLineItWasAskedFor() async throws {
        let vm = VM(lines: [3, 5, 6], isLoaded: true)
        let (session, peer) = try await makeSession(vm)
        try await session.start(breakpoints: [(unit: Self.calcBody, line: 4)])

        try await session.removeBreakpoint(in: Self.calcBody, line: 4)
        #expect(clears(peer) == [clear(vm.request(atLine: 5))])
        #expect(await session.stop() == .ended)
    }

    // The unit is not loaded at start: the line map places line 4 on line 5, and the class's line table then moves it
    // to line 6 when the unit loads.
    @Test func testAPendingBreakpointIsRemovedByItsLineAfterItsUnitLoads() async throws {
        let vm = VM(lines: [3, 6], isLoaded: false)
        // Lines 3, 5 and 6 have code in DBMS_DEBUG's line map.
        let helper = ScriptedChannel { sql in
            sql.contains("GET_LINE_MAP") ? [OracleDebugPayload.encode(["0", "6", "68"])] : []
        }
        let (session, peer) = try await makeSession(vm, helper: helper)
        try await session.start(breakpoints: [(unit: Self.calcBody, line: 4)])
        vm.load()
        #expect(try await session.setBreakpoint(in: Self.calcBody, line: 3) == 3)

        try await session.removeBreakpoint(in: Self.calcBody, line: 4)
        #expect(clears(peer) == [clear(vm.request(atLine: 6))])
        #expect(await session.stop() == .ended)
    }

    // Lines 4 and 5 both land on line 5: the breakpoint stays until the host has removed both.
    @Test func testABreakpointTwoStartLinesLandedOnStaysUntilBothAreRemoved() async throws {
        let vm = VM(lines: [3, 5, 6], isLoaded: true)
        let (session, peer) = try await makeSession(vm)
        try await session.start(breakpoints: [(unit: Self.calcBody, line: 4), (unit: Self.calcBody, line: 5)])

        try await session.removeBreakpoint(in: Self.calcBody, line: 4)
        #expect(clears(peer).isEmpty)
        try await session.removeBreakpoint(in: Self.calcBody, line: 5)
        #expect(clears(peer) == [clear(vm.request(atLine: 5))])
        #expect(await session.stop() == .ended)
    }

    // A Clear the VM refuses leaves the breakpoint set, so removing it again sends another Clear.
    @Test func testARefusedClearCanBeRetried() async throws {
        let vm = VM(lines: [3, 5, 6], isLoaded: true)
        let (session, peer) = try await makeSession(vm)
        try await session.start(breakpoints: [])
        #expect(try await session.setBreakpoint(in: Self.calcBody, line: 5) == 5)
        vm.refuseNextClear()

        await #expect(throws: (any Error).self) { try await session.removeBreakpoint(in: Self.calcBody, line: 5) }
        try await session.removeBreakpoint(in: Self.calcBody, line: 5)
        #expect(clears(peer) == [clear(vm.request(atLine: 5)), clear(vm.request(atLine: 5))])
        #expect(await session.stop() == .ended)
    }

    // A breakpoint set after start answers the line it landed on, which is the line the host removes it by.
    @Test func testABreakpointSetLaterIsRemovedByTheLineItAnswered() async throws {
        let vm = VM(lines: [3, 5, 6], isLoaded: true)
        let (session, peer) = try await makeSession(vm)
        try await session.start(breakpoints: [])
        #expect(try await session.setBreakpoint(in: Self.calcBody, line: 4) == 5)

        try await session.removeBreakpoint(in: Self.calcBody, line: 5)
        #expect(clears(peer) == [clear(vm.request(atLine: 5))])
        #expect(await session.stop() == .ended)
    }
}
