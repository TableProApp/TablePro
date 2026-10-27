import Foundation
import os
@testable import TableProOracleCore

// A peer that answers each command through `respond`, the reply renumbered to the command's id, and records what this
// side sent. A nil answer is never sent, so the command stays in flight.
final class RespondingPeer: OracleJDWPTransport, @unchecked Sendable {
    struct Sent {
        let commandSet: UInt8
        let command: UInt8
        let body: Data
    }

    private struct State {
        var inbound: [Data] = [OracleJDWPPacket.handshake]
        var waiter: CheckedContinuation<Data?, Never>?
        var closed = false
        var sent: [Sent] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let respond: @Sendable (Sent) -> (events: [Data], errorCode: UInt16, body: Data)?

    init(respond: @escaping @Sendable (Sent) -> (events: [Data], errorCode: UInt16, body: Data)?) {
        self.respond = respond
    }

    var sent: [Sent] { state.withLock { $0.sent } }

    func send(_ data: Data) async throws {
        guard data != OracleJDWPPacket.handshake, let (packet, _) = try OracleJDWPPacket.decode(from: data),
              case let .command(id, commandSet, command, body) = packet else { return }
        let sent = Sent(commandSet: commandSet, command: command, body: body)
        state.withLock { $0.sent.append(sent) }
        guard let answer = respond(sent) else { return }
        for event in answer.events {
            deliver(event)
        }
        deliver(OracleJDWPPacket.reply(id: id, errorCode: answer.errorCode, data: answer.body).encoded)
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

func replyBody(_ packet: Data) -> Data {
    guard let decoded = try? OracleJDWPPacket.decode(from: packet), case let .reply(_, _, body) = decoded.packet else { return Data() }
    return body
}
