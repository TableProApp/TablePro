import Foundation
import os
@testable import TableProOracleCore
import Testing

// Plays the database's side of the recorded conversation: each command this side sends is answered with the bytes the
// database sent at that point, the reply renumbered to the command's id.
private final class ReplayTransport: OracleJDWPTransport, @unchecked Sendable {
    private struct State {
        var inbound: [Data] = []
        var waiter: CheckedContinuation<Data?, Never>?
        var sent: [Data] = []
        var closed = false
    }

    private let answers: [UInt8: [Data]]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(greeting: Data, answers: [UInt8: [Data]]) {
        self.answers = answers
        deliver(greeting)
    }

    var sent: [Data] { state.withLock { $0.sent } }

    func send(_ data: Data) async throws {
        state.withLock { $0.sent.append(data) }
        guard data.count >= 11 else { return }
        let id = data.prefix(8).suffix(4)
        let command = data[data.startIndex + 10]
        for answer in answers[command] ?? [] {
            var packet = answer
            if packet[packet.startIndex + 8] & 0x80 != 0 {
                packet.replaceSubrange(packet.startIndex + 4..<packet.startIndex + 8, with: id)
            }
            deliver(packet)
        }
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
        let waiter = state.withLock { current -> CheckedContinuation<Data?, Never>? in
            current.closed = true
            defer { current.waiter = nil }
            return current.waiter
        }
        waiter?.resume(returning: nil)
    }
}

struct OracleJDWPConnectionTests {
    @Test func testRecordedHandshakeRepliesAndEventsReachTheirCallers() async throws {
        let transport = ReplayTransport(
            greeting: OracleJDWPPacket.handshake,
            answers: [
                OracleJDWPCommand.idSizes: [OracleJDWPRecording.vmStartEvent, OracleJDWPRecording.idSizesReply],
                OracleJDWPCommand.methods: [OracleJDWPRecording.methodsReply]
            ]
        )
        let connection = OracleJDWPConnection(transport: transport)
        try await connection.handshake()

        let sizesReply = try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.idSizes)
        var reader = OracleJDWPReader(sizesReply, sizes: .oracle)
        #expect(try reader.i32() == 4)

        var commands = connection.commands.makeAsyncIterator()
        let event = try #require(await commands.next())
        guard case let .command(_, 64, 100, body) = event else {
            Issue.record("expected the composite event")
            return
        }
        #expect(try OracleJDWPEventSet.decode(body, sizes: .oracle).events == [.vmStart(thread: 1)])

        var writer = OracleJDWPWriter(sizes: .oracle)
        writer.id(2, .referenceType)
        let methods = try OracleJDWPMethod.decodeList(
            try await connection.send(OracleJDWPCommand.referenceType, OracleJDWPCommand.methods, writer.data),
            sizes: .oracle
        )
        #expect(methods.map(\.name) == ["<clinit>", "ADD_TAX", "RUN", "ADD_TAX"])
        #expect(transport.sent.first == OracleJDWPPacket.handshake)

        await connection.close()
        await #expect(throws: OracleJDWPError.closed) {
            try await connection.send(OracleJDWPCommand.virtualMachine, OracleJDWPCommand.resume)
        }
    }

    @Test func testAPeerThatAnswersSomethingElseFailsTheHandshake() async {
        let transport = ReplayTransport(greeting: Data("HTTP/1.1 400 Ba".utf8), answers: [:])
        let connection = OracleJDWPConnection(transport: transport)
        await #expect(throws: OracleJDWPError.handshakeFailed) {
            try await connection.handshake()
        }
    }

    @Test func testAReplyErrorCodeComesBackAsAnError() async throws {
        let failing = OracleJDWPPacket.reply(id: 0, errorCode: 35, data: Data()).encoded
        let transport = ReplayTransport(
            greeting: OracleJDWPPacket.handshake,
            answers: [OracleJDWPCommand.frameValues: [failing]]
        )
        let connection = OracleJDWPConnection(transport: transport)
        try await connection.handshake()
        await #expect(throws: OracleJDWPError.reply(code: 35)) {
            try await connection.send(OracleJDWPCommand.stackFrame, OracleJDWPCommand.frameValues)
        }
    }
}
