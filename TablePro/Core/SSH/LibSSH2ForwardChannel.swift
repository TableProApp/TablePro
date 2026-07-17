//
//  LibSSH2ForwardChannel.swift
//  TablePro
//

import Foundation

import CLibSSH2

/// Result of a single non-blocking attempt to open a forwarding channel.
internal enum SSHForwardChannelAttempt {
    case opened(OpaquePointer)
    case wouldBlock(RelayDirections)
    case failed(Int32)
}

/// One non-blocking attempt to open a forwarding channel. Implementations must return
/// promptly: the caller drives retries and owns the deadline, so an implementation that
/// blocks would stall every other channel sharing the session.
internal protocol SSHForwardChannelOpening {
    func attemptOpen() -> SSHForwardChannelAttempt
}

/// Bridges `SSHForwardChannelOpening` to libssh2. Each attempt takes the session queue
/// only long enough to try the open and read back the error and block directions, so a
/// slow open never holds the queue against relays or keep-alive.
internal struct LibSSH2ForwardChannelOpener: SSHForwardChannelOpening {
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
            guard errorCode == LIBSSH2_ERROR_EAGAIN else { return .failed(errorCode) }

            return .wouldBlock(RelayDirections(libssh2BlockDirections: libssh2_session_block_directions(session)))
        }
    }
}

/// Opens the channel that carries forwarded traffic to the destination. The two libssh2
/// entry points behave identically to the caller: both return a channel that reads and
/// writes the same way, and both signal "not ready yet" with `LIBSSH2_ERROR_EAGAIN`.
internal enum LibSSH2ForwardChannel {
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

    private static let originHost = "127.0.0.1"
}
