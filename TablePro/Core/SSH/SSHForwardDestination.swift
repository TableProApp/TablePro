//
//  SSHForwardDestination.swift
//  TablePro
//

import Foundation

/// What the SSH server connects to on the far end of a local forward. A TCP destination
/// opens a `direct-tcpip` channel; a socket destination opens a `direct-streamlocal@openssh.com`
/// channel, the equivalent of `ssh -L <localPort>:/path/to/socket`.
internal enum SSHForwardDestination: Sendable, Hashable {
    case tcp(host: String, port: Int)
    case unixSocket(path: String)

    var isUnixSocket: Bool {
        switch self {
        case .tcp: return false
        case .unixSocket: return true
        }
    }

    var logDescription: String {
        switch self {
        case .tcp(let host, let port): return "\(host):\(port)"
        case .unixSocket(let path): return path
        }
    }
}
