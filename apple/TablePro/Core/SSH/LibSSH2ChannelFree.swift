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

    // Another relay can read the CLOSE reply off the shared socket and leave it quiet, so free runs
    // again after every wait. An EOF that would block is sent again first: libssh2 keeps it as the
    // session's next packet and turns every other send away until the same call sends it.
    static func run(
        channel: OpaquePointer,
        session: OpaquePointer,
        sessionQueue: DispatchQueue,
        transportFD: Int32,
        sendEOF: Bool = false,
        deadline: Date = Date().addingTimeInterval(deadlineSeconds),
        isActive: @escaping () -> Bool
    ) -> SSHChannelFreeOutcome {
        var eofPending = sendEOF
        return SSHChannelFreePump(
            attemptFree: {
                sessionQueue.sync {
                    if eofPending {
                        guard libssh2_channel_send_eof(channel) != LIBSSH2_ERROR_EAGAIN else { return blocked(session) }
                        eofPending = false
                    }
                    guard libssh2_channel_free(channel) == LIBSSH2_ERROR_EAGAIN else { return .finished }
                    return blocked(session)
                }
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
