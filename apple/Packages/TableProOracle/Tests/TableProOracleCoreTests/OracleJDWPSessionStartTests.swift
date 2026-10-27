import Foundation
import os
@testable import TableProOracleCore
import Testing

struct OracleJDWPSessionStartTests {
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

    // A logon trigger or startup command that ran the package loads it before CONNECT_TCP, so no CLASS_PREPARE may
    // announce it; the session finds it with ClassesBySignature and sets the entry breakpoint before resuming.
    @Test func testAnAlreadyLoadedUnitGetsItsEntryBreakpointBeforeTheResume() async throws {
        let requestIDs = OSAllocatedUnfairLock(initialState: Int32(0))
        let peer = RespondingPeer { sent in
            var writer = OracleJDWPWriter(sizes: .oracle)
            switch (sent.commandSet, sent.command) {
            case (OracleJDWPCommand.virtualMachine, OracleJDWPCommand.idSizes):
                return ([OracleJDWPRecording.vmStartEvent], 0, replyBody(OracleJDWPRecording.idSizesReply))
            case (OracleJDWPCommand.virtualMachine, OracleJDWPCommand.classesBySignature):
                writer.i32(1)
                writer.u8(1)
                writer.id(2, .referenceType)
                writer.i32(7)
            case (OracleJDWPCommand.referenceType, OracleJDWPCommand.methods):
                return ([], 0, replyBody(OracleJDWPRecording.methodsReply))
            case (OracleJDWPCommand.method, OracleJDWPCommand.lineTable):
                return ([], 0, replyBody(OracleJDWPRecording.lineTableReply))
            case (OracleJDWPCommand.eventRequest, OracleJDWPCommand.set):
                writer.i32(requestIDs.withLock { id -> Int32 in
                    id += 1
                    return id
                })
            default:
                break
            }
            return ([], 0, writer.data)
        }
        let session = try await makeSession(peer)
        try await session.start(breakpoints: [])
        let sent = peer.sent
        let breakpoint = sent.firstIndex {
            $0.commandSet == OracleJDWPCommand.eventRequest && $0.command == OracleJDWPCommand.set
                && $0.body.first == OracleJDWPEventKind.breakpoint.rawValue
        }
        let resume = sent.firstIndex { $0.commandSet == OracleJDWPCommand.virtualMachine && $0.command == OracleJDWPCommand.resume }
        #expect(breakpoint != nil)
        #expect(resume != nil)
        if let breakpoint, let resume {
            #expect(breakpoint < resume)
        }
        #expect(await session.stop() == .ended)
    }

    // An error code the database answers becomes a written error, never an unreadable Swift one.
    @Test func testARefusedCommandBecomesAWrittenError() async throws {
        let peer = RespondingPeer { sent in
            if sent.commandSet == OracleJDWPCommand.virtualMachine, sent.command == OracleJDWPCommand.idSizes {
                return ([OracleJDWPRecording.vmStartEvent], 0, replyBody(OracleJDWPRecording.idSizesReply))
            }
            return ([], 99, Data())
        }
        let session = try await makeSession(peer)
        await #expect(throws: OracleDebugError.debuggerRefused(code: 99)) {
            try await session.start(breakpoints: [])
        }
        #expect(await session.stop() == .ended)
    }

    // One slot the database cannot read fails the batch; each is then read alone and only that one is left out.
    @Test func testAnUnreadableSlotIsSkippedInsteadOfFailingTheFrame() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [[Int]]())
        let values = try await OracleJDWPDebugSession.readSlots([0, 1, 2]) { slots in
            calls.withLock { $0.append(slots) }
            if slots.contains(1) { throw OracleJDWPError.reply(code: 35) }
            return slots.map { OracleJDWPValue.object(tag: OracleJDWPValue.objectTag, id: UInt64($0 + 10)) }
        }
        #expect(values == [.object(tag: OracleJDWPValue.objectTag, id: 10), nil, .object(tag: OracleJDWPValue.objectTag, id: 12)])
        #expect(calls.withLock { $0 } == [[0, 1, 2], [0], [1], [2]])
    }
}
