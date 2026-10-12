//
//  SSHForwardFailure.swift
//  TableProSSHTransport
//

import Foundation

/// Why a forwarding channel could not be opened, in terms the transport owns.
///
/// The transport stops here rather than building the error the user reads: each app spells its
/// own `SSHTunnelError`, and a package target has no strings catalog to localize one from. The
/// destination travels with the reason because a refused unix socket and a refused TCP port send
/// the user to different settings on the server.
public enum SSHForwardFailure: Equatable, Sendable {
    case refused(destination: SSHForwardDestination, detail: String)
    case timedOut(destination: SSHForwardDestination, seconds: Int)
}
