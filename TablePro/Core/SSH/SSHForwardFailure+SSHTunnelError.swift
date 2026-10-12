//
//  SSHForwardFailure+SSHTunnelError.swift
//  TablePro
//

import Foundation

import TableProSSHTransport

extension SSHForwardFailure {
    /// The app's own error for a transport-level forwarding failure. The transport stops at
    /// `SSHForwardFailure` because it has no strings catalog to localize from, and because a
    /// refused unix socket and a refused TCP port send the user to different sshd settings.
    var tunnelError: SSHTunnelError {
        switch self {
        case .refused(let destination, let detail):
            if case .unixSocket(let path) = destination {
                return .socketForwardingRefused(path: path, detail: detail)
            }
            return .forwardRefused(destination: destination.logDescription, detail: detail)
        case .timedOut(let destination, let seconds):
            return .forwardTimedOut(destination: destination.logDescription, seconds: seconds)
        }
    }
}
