//
//  LibSSH2ChannelFree.swift
//  TablePro
//
//  Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
//  MainActor isolation, so every top-level declaration states its own.
//

import Foundation

import CLibSSH2
import TableProSSHTransport

nonisolated internal enum LibSSH2ChannelFree {
    static let pollTimeoutMs: Int32 = 100
    // The keep-alive's own limit: a packet still unsent by then holds every other send on the session.
    static let deadlineSeconds: TimeInterval = 30

    // Another relay can read the CLOSE reply off the shared socket and leave it quiet, so free runs again after
    // every wait. The EOF goes first, on its own: channel_close would send it anyway, from a packet on its stack
    // that a retry from another frame cannot finish (stackPacketReadiness), so it waits for room to go whole. A
    // wait on another packet is bounded by the poll timeout, as only that packet's own call can finish it.
    static func run(
        channel: OpaquePointer,
        session: OpaquePointer,
        pump: SSHSessionPump,
        transportFD: Int32,
        deadline: Date = Date().addingTimeInterval(deadlineSeconds),
        isActive: @escaping () -> Bool
    ) -> SSHChannelFreeOutcome {
        var eofSent = false
        let turn = SSHSendTurn(pump: pump)
        defer { turn.end() }
        return SSHChannelFreePump(
            attemptFree: {
                let attempt: SSHChannelFreeAttempt = pump.perform {
                    if !eofSent {
                        switch stackPacketReadiness(session: session, transportFD: transportFD) {
                        case .socketFull: return .wouldBlock(.outbound)
                        case .sendPending: return .wouldBlock(.inbound)
                        case .ready, .gone: break
                        }
                        guard libssh2_channel_send_eof(channel) != LIBSSH2_ERROR_EAGAIN else { return blocked(session) }
                        eofSent = true
                    }
                    guard libssh2_channel_free(channel) == LIBSSH2_ERROR_EAGAIN else { return .finished }
                    return blocked(session)
                }
                // Past the EOF and the CLOSE the free only waits for the server's reply.
                if case .wouldBlock(let directions) = attempt {
                    turn.waitsToSend(!eofSent || directions.contains(.outbound))
                } else {
                    turn.end()
                }
                return attempt
            },
            isActive: isActive,
            deadline: deadline,
            waitForTransport: { directions in
                _ = pollReady(fd: transportFD, directions: directions, timeoutMs: pollTimeoutMs)
            }
        ).run()
    }

    private static func blocked(_ session: OpaquePointer) -> SSHChannelFreeAttempt {
        .wouldBlock(RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session)))
    }
}
