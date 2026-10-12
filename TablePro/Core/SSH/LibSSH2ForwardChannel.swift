//
//  LibSSH2ForwardChannel.swift
//  TablePro
//
//  Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
//  MainActor isolation. Every top-level declaration states its own isolation for that reason;
//  scripts/ci/check-ios-shared-isolation.py holds it.
//

import Foundation

import CLibSSH2
import TableProSSHTransport

/// Bridges `SSHForwardChannelOpening` to libssh2. Each attempt takes the session queue
/// only long enough to try the open and read back the error and block directions, so a
/// slow open never holds the queue against relays or keep-alive.
nonisolated internal struct LibSSH2ForwardChannelOpener: SSHForwardChannelOpening {
    let session: OpaquePointer
    let destination: SSHForwardDestination
    let originPort: Int
    let sessionQueue: DispatchQueue

    func attemptOpen() -> SSHForwardChannelAttempt {
        sessionQueue.sync {
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

/// Opens the channel that carries forwarded traffic to the destination. The two libssh2
/// entry points behave identically to the caller: both return a channel that reads and
/// writes the same way, and both signal "not ready yet" with `LIBSSH2_ERROR_EAGAIN`.
nonisolated internal enum LibSSH2ForwardChannel {
    static func open(
        session: OpaquePointer,
        destination: SSHForwardDestination,
        originPort: Int
    ) -> OpaquePointer? {
        switch destination {
        case .tcp(let host, let port):
            return libssh2_channel_direct_tcpip_ex(
                session,
                host,
                Int32(port),
                Self.originHost,
                Int32(originPort)
            )
        case .unixSocket(let path):
            return libssh2_channel_direct_streamlocal_ex(
                session,
                path,
                Self.originHost,
                Int32(originPort)
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
