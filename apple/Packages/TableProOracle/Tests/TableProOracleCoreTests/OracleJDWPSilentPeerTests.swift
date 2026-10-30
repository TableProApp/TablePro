import Foundation
import os
@testable import TableProOracleCore
import Testing

// A peer that completes the handshake, answers IDSizes with the recorded reply and its VM_START, then never answers
// again: what a hung or hostile server looks like after the database connected back.
private final class SilentPeerTransport: OracleJDWPTransport, @unchecked Sendable {
    private struct State {
        var inbound: [Data] = [OracleJDWPPacket.handshake]
        var waiter: CheckedContinuation<Data?, Never>?
        var closed = false
        var commands = 0
        var commandWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isClosed: Bool { state.withLock { $0.closed } }

    // Returns once this many commands (packets after the handshake) have been sent.
    func commandsSent(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { current -> Bool in
                if current.commands >= count { return true }
                current.commandWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func closedEvent() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { current -> Bool in
                if current.closed { return true }
                current.closeWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func send(_ data: Data) async throws {
        guard data.count >= 11 else { return }
        let reached = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.commands += 1
            let ready = current.commandWaiters.filter { $0.count <= current.commands }.map(\.continuation)
            current.commandWaiters.removeAll { $0.count <= current.commands }
            return ready
        }
        for waiter in reached {
            waiter.resume()
        }
        guard data[data.startIndex + 9] == OracleJDWPCommand.virtualMachine,
              data[data.startIndex + 10] == OracleJDWPCommand.idSizes else { return }
        var reply = OracleJDWPRecording.idSizesReply
        reply.replaceSubrange(reply.startIndex + 4..<reply.startIndex + 8, with: data.prefix(8).suffix(4))
        deliver(OracleJDWPRecording.vmStartEvent)
        deliver(reply)
    }

    private func deliver(_ data: Data) {
        let waiter = state.withLock { current -> CheckedContinuation<Data?, Never>? in
            if let waiter = current.waiter {
                current.waiter = nil
                return waiter
            }
            current.inbound.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { current -> Data?? in
                if !current.inbound.isEmpty { return .some(current.inbound.removeFirst()) }
                if current.closed { return .some(nil) }
                current.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func close() {
        let (waiter, closeWaiters) = state.withLock { current -> (CheckedContinuation<Data?, Never>?, [CheckedContinuation<Void, Never>]) in
            current.closed = true
            defer {
                current.waiter = nil
                current.closeWaiters.removeAll()
            }
            return (current.waiter, current.closeWaiters)
        }
        waiter?.resume(returning: nil)
        for closeWaiter in closeWaiters {
            closeWaiter.resume()
        }
    }
}

struct OracleJDWPSilentPeerTests {
    private func session(replyTimeout: Duration) async throws -> (OracleJDWPDebugSession, SilentPeerTransport) {
        let transport = SilentPeerTransport()
        let connection = OracleJDWPConnection(transport: transport, replyTimeout: replyTimeout)
        try await connection.handshake()
        let unit = OracleDebugUnit(owner: "PROBE", name: "PKG_CALC", kind: .packageBody)
        let entryPoint = OracleDebugEntryPoint(
            entry: OracleDebugEntry(unit: unit, subprogram: "RUN", subprogramID: 3),
            overload: nil,
            parameters: [],
            result: nil
        )
        let offline = OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "x"))
        let session = OracleJDWPDebugSession(
            connection: connection,
            target: offline,
            helper: offline,
            entryPoint: entryPoint,
            invocation: OracleDebugStatements.Invocation(block: "BEGIN NULL; END;", binds: []),
            connectCall: Task { .success([]) },
            notices: []
        )
        return (session, transport)
    }

    // The ClassPrepare request after VM_START gets no answer; the reply timeout ends the start and the socket.
    @Test func testAStartAgainstASilentPeerFailsWithinTheReplyTimeout() async throws {
        let (session, transport) = try await session(replyTimeout: .milliseconds(300))
        let started = ContinuousClock.now
        await #expect(throws: OracleDebugError.debuggerStoppedAnswering) {
            try await session.start(breakpoints: [])
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(transport.isClosed)
    }

    // Tab close or module off cancels the start: it returns at once and the socket closes, which ends the target.
    @Test func testCancellingAStartWaitingOnASilentPeerReturnsPromptly() async throws {
        let (session, transport) = try await session(replyTimeout: .seconds(60))
        let start = Task { try await session.start(breakpoints: []) }
        // IDSizes is answered; the ClassPrepare request after VM_START is the one left waiting.
        await transport.commandsSent(2)
        let started = ContinuousClock.now
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        await transport.closedEvent()
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func testAReplyThatNeverComesFailsTheCommandAndClosesTheConnection() async throws {
        let transport = SilentPeerTransport()
        let connection = OracleJDWPConnection(transport: transport, replyTimeout: .milliseconds(200))
        try await connection.handshake()
        await #expect(throws: OracleJDWPError.timedOut) {
            try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.resume)
        }
        #expect(await connection.closed)
        #expect(transport.isClosed)
        await #expect(throws: OracleJDWPError.closed) {
            try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.resume)
        }
    }

    @Test func testACancelledCommandThrowsCancellationAndClosesTheConnection() async throws {
        let transport = SilentPeerTransport()
        let connection = OracleJDWPConnection(transport: transport, replyTimeout: .seconds(60))
        try await connection.handshake()
        let waiting = Task { try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.resume) }
        await transport.commandsSent(1)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await transport.closedEvent()
        #expect(await connection.closed)
    }
}
