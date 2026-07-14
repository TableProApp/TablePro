//
//  LibSSH2ForwardChannel.swift
//  TablePro
//

import Foundation

import CLibSSH2

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
