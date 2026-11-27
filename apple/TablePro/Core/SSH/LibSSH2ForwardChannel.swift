//
//  LibSSH2ForwardChannel.swift
//  TablePro
//
//  Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
//  MainActor isolation. Every top-level declaration states its own isolation for that reason;
//  the iOS build is the check.
//

import Foundation

import CLibSSH2
import TableProSSHTransport

// Bridges `SSHForwardChannelOpening` to libssh2. Each attempt takes the session queue
// only long enough to try the open and read back the error and block directions, so a
// slow open never holds the queue against relays or keep-alive.
nonisolated internal struct LibSSH2ForwardChannelOpener: SSHForwardChannelOpening {
    let session: OpaquePointer
    let destination: SSHForwardDestination
    let originPort: Int
    let pump: SSHSessionPump
    let turn: SSHSendTurn

    func attemptOpen() -> SSHForwardChannelAttempt {
        let attempt = openOnce()
        if case .wouldBlock(let directions) = attempt {
            turn.waitsToSend(directions.contains(.outbound))
        } else {
            turn.end()
        }
        return attempt
    }

    private func openOnce() -> SSHForwardChannelAttempt {
        pump.perform {
            if let channel = LibSSH2ForwardChannel.open(
                session: session,
                destination: destination,
                originPort: originPort
            ) {
                return .opened(channel)
            }

            let errorCode = libssh2_session_last_errno(session)
            guard errorCode == LIBSSH2_ERROR_EAGAIN else {
                return .failed(code: errorCode, message: LibSSH2ForwardChannel.lastErrorMessage(session: session))
            }

            return .wouldBlock(RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session)))
        }
    }
}

// Opens the channel that carries forwarded traffic to the destination, signalling "not ready yet" with
// `LIBSSH2_ERROR_EAGAIN`. libssh2's direct-tcpip and streamlocal calls fix the window at 2 MiB, and a window
// adjust after them is spent once: ssh2_channel_read refills only to the window the channel opened with.
nonisolated internal enum LibSSH2ForwardChannel {
    // Another open or relay can read this channel's reply into libssh2's queue and leave the socket
    // quiet, so a quiet wait is a retry and only the deadline ends an open.
    static let openPollTimeoutMs: Int32 = 100

    static func open(
        session: OpaquePointer,
        destination: SSHForwardDestination,
        originPort: Int
    ) -> OpaquePointer? {
        let request = destination.channelRequest(originHost: Self.originHost, originPort: originPort)
        return request.message.withUnsafeBytes { message in
            libssh2_channel_open_ex(
                session,
                request.channelType,
                UInt32(request.channelType.utf8.count),
                SSHForwardChannelRequest.receiveWindowBytes,
                SSHForwardChannelRequest.maximumPacketBytes,
                message.bindMemory(to: CChar.self).baseAddress,
                UInt32(message.count)
            )
        }
    }

    static func lastErrorMessage(session: OpaquePointer) -> String {
        var messagePointer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        libssh2_session_last_error(session, &messagePointer, &messageLength, 0)

        guard let messagePointer else { return String(localized: "Unknown error") }
        let message = String(cString: messagePointer)
        return message.isEmpty ? String(localized: "Unknown error") : message
    }

    private static let originHost = "127.0.0.1"
}
